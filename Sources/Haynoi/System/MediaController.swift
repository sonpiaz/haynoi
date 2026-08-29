import AppKit

/// Decides what happens to everything else the Mac is playing while you dictate.
///
/// The rule Haynoi commits to: **your voice never competes with your speakers,
/// and nothing you cannot resume gets stopped.**
///
/// Two kinds of audio, two different answers:
///
///  * **Media we can name** — Spotify and Apple Music, driven by AppleScript.
///    `pause` and `play` are explicit, so these get **paused** and resumed at
///    the exact position on release.
///  * **Media we cannot name** — a YouTube tab, a podcast app, VLC. There is
///    no way to address these except the play/pause media key, and that key is
///    a *toggle*: get the guess wrong and it starts something instead of
///    stopping it. So they get **ducked** too.
///  * **Live audio** — a Zoom/Meet/Teams call, a stream, a FaceTime. There is
///    nothing to resume; pausing is destructive. It gets **ducked** to a
///    fraction of its volume and restored on release.
///
/// The interesting problem is telling the two apart, and the answer is not an
/// app list. Zoom sitting open all day is not a meeting; Chrome is a video
/// player and a conference room depending on the tab. So Haynoi asks CoreAudio
/// what each process is *doing* right now and applies the conversation test:
///
///     a process that is playing audio AND capturing the mic
///     at the same time is in a conversation — duck it, never pause it.
///
/// That single test covers Zoom, Google Meet in a browser, Teams, Discord,
/// Slack huddles and FaceTime without naming any of them, and it stops
/// pausing music just because a call app happens to be running.
///
/// Everything is decided from evidence, and the one action that could not be
/// taken back — the play/pause media key — is gone. CoreAudio reports whether a
/// process has an output stream open, not whether it is making a sound, and a
/// browser sitting on a loaded track reports the former all day. Every remaining
/// action is safe under that uncertainty: AppleScript `pause` is explicit, and
/// ducking is inaudible when there was nothing to hear.
enum MediaController {

    /// AppleScript-controllable players. Preferred over the media key because
    /// pause/play is explicit: no toggle ambiguity, exact resume position.
    private static let scriptablePlayers: [String: String] = [
        "com.spotify.client": "Spotify",
        "com.apple.Music": "Music",
    ]

    /// System audio clients that are always "playing" something (Siri's
    /// listener, UI sounds, accessibility). Counting them as media would mean
    /// Haynoi thinks audio is playing every single time.
    private static let systemNoise: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.siriactionsd",
        "com.apple.controlcenter",
        "com.apple.audiomxd",
        "com.apple.mediaremoted",
        "com.apple.universalaccessd",
        "com.apple.accessibility.heard",
        "systemsoundserverd",
    ]

    /// Delay before the volume is lowered, so Haynoi's own start tone plays at
    /// the level the user set. Also keeps every HAL write off the moment the
    /// mic goes live — nothing here may add latency to recording.
    private static let duckDelay: TimeInterval = 0.18

    /// How long to wait before checking whether a pause actually worked.
    /// Media keys get swallowed, and Automation permission for Spotify can be
    /// denied; either way the audio is still playing and ducking is the answer.
    private static let pauseVerifyDelay: TimeInterval = 0.45

    private static let queue = DispatchQueue(label: "com.sonpiaz.haynoi.media-controller")

    /// Guarded by `queue`.
    private static var pausedApps: [String] = []
    /// Bumped on every start/stop so a delayed verification from a previous
    /// dictation can never duck audio after we have already restored it.
    private static var session: UInt64 = 0

    /// The toggle was never registered, so `bool(forKey:)` read false on a fresh
    /// install while Settings showed the switch on. Registering here keeps the
    /// default with the feature that owns it.
    private static let registerDefaults: Void = {
        UserDefaults.standard.register(defaults: ["muteMusic": true, "duckFraction": 0.2])
    }()

    private static var isEnabled: Bool {
        _ = registerDefaults
        return UserDefaults.standard.bool(forKey: "muteMusic")
    }

    // MARK: - Entry points

    /// Call once at launch — repairs a volume left low by a crash mid-dictation.
    static func repairAfterCrash() {
        _ = registerDefaults
        queue.async { AudioDucker.restoreStaleDuck() }
    }

    static func pauseIfPlaying() {
        guard isEnabled else { return }
        queue.async {
            session &+= 1
            let token = session
            let scene = Scene.capture()
            guard scene.hasPlayback else { return }

            // Live conversation in the mix — lower it, never stop it.
            if scene.hasLiveAudio {
                queue.asyncAfter(deadline: .now() + duckDelay) {
                    guard token == session else { return }
                    AudioDucker.duck()
                }
            }

            // Resumable media — stop it properly.
            for appName in scene.appsToPause {
                run("tell application \"\(appName)\" to pause")
                pausedApps.append(appName)
            }
            if scene.duckRemainingMedia {
                // Something we cannot address safely by name. Ducking is
                // unambiguous; a media key here could start a paused player
                // instead of stopping the browser.
                queue.asyncAfter(deadline: .now() + duckDelay) {
                    guard token == session else { return }
                    AudioDucker.duck()
                }
            }

            // Did the pause actually take? Automation can be denied and media
            // keys can be ignored. Check, and fall back to ducking.
            guard !scene.pauseTargets.isEmpty else { return }
            queue.asyncAfter(deadline: .now() + pauseVerifyDelay) {
                guard token == session else { return }
                if Scene.stillPlaying(scene.pauseTargets) {
                    NSLog("[Haynoi] Media did not pause — ducking instead")
                    AudioDucker.duck()
                }
            }
        }
    }

    static func resumeIfPaused() {
        queue.async {
            session &+= 1

            // Volume first, so resumed audio comes back at the right level
            // rather than fading up a beat later.
            AudioDucker.restore()

            let apps = pausedApps
            pausedApps = []
            for app in apps { run("tell application \"\(app)\" to play") }
        }
    }

    // MARK: - Scene

    /// A snapshot of what the Mac is playing, and the plan that follows from it.
    /// Internal (not private) so the policy can be unit-tested without a mic,
    /// a call, or a sound card — see `MediaPolicyTests`.
    struct Scene {
        /// AppleScript names of players we can pause precisely.
        let appsToPause: [String]
        /// Identities to re-check after the pause attempt.
        let pauseTargets: Set<String>
        let hasLiveAudio: Bool
        let duckRemainingMedia: Bool

        var hasPlayback: Bool {
            hasLiveAudio || !appsToPause.isEmpty || duckRemainingMedia
        }

        static func capture() -> Scene {
            let processes = SystemAudio.processes()

            // macOS < 14.2: no per-process data. Fall back to the coarse
            // "is the output device running" signal plus the running-app
            // heuristic — the pre-14.2 behaviour, minus the blind media key
            // when nothing is playing.
            guard !processes.isEmpty else { return legacyCapture() }

            return plan(
                processes: processes,
                myPID: getpid(),
                myBundleID: Bundle.main.bundleIdentifier
            )
        }

        /// The policy itself, as a pure function of what the machine is playing.
        /// No CoreAudio, no AppKit, no clock — so every branch is testable.
        static func plan(
            processes: [SystemAudio.AudioProcess],
            myPID: pid_t,
            myBundleID: String?
        ) -> Scene {
            let relevant = processes.filter { process in
                process.pid != myPID
                    && process.bundleID != myBundleID
                    && !systemNoise.contains(process.bundleID ?? "")
            }

            let conversing = Set(relevant.filter(\.isCapturing).map(\.identity))
            let playing = relevant.filter(\.isPlaying)

            let live = playing.filter { conversing.contains($0.identity) }
            let media = playing.filter { !conversing.contains($0.identity) }

            var scriptable: [String: String] = [:] // bundle id → AppleScript name
            var others: Set<String> = []
            for process in media {
                if let bundleID = process.bundleID, let appName = MediaController.scriptablePlayers[bundleID] {
                    scriptable[bundleID] = appName
                } else {
                    others.insert(process.identity)
                }
            }

            // Anything we cannot name gets ducked, never toggled.
            //
            // `isPlaying` is kAudioProcessPropertyIsRunningOutput — "has an
            // output stream open", which is not the same as "is making a
            // sound". Measured on a silent Mac: com.apple.WebKit.GPU reports
            // it continuously, because a browser holding an idle audio context
            // is enough. The play/pause media key is a *toggle*, so firing it
            // on that evidence started the last track instead of stopping
            // anything — and the same key on release then cut it off, after
            // the volume had already been restored, with an audible thump.
            //
            // Ducking cannot make that mistake: it is non-destructive, and if
            // nothing was audible it is inaudible.
            return Scene(
                appsToPause: Array(scriptable.values),
                pauseTargets: Set(scriptable.keys).union(others),
                hasLiveAudio: !live.isEmpty,
                duckRemainingMedia: !others.isEmpty
            )
        }

        /// Pre-14.2 path: no per-process truth available.
        private static func legacyCapture() -> Scene {
            let outputActive = SystemAudio.defaultOutputDevice.map(SystemAudio.isOutputActive) ?? true

            if isAppRunning("com.spotify.client") {
                return Scene(appsToPause: ["Spotify"], pauseTargets: [], hasLiveAudio: false,
                             duckRemainingMedia: false)
            }
            if isAppRunning("com.apple.Music") {
                return Scene(appsToPause: ["Music"], pauseTargets: [], hasLiveAudio: false,
                             duckRemainingMedia: false)
            }
            // A conferencing app being *open* is the only live signal available
            // here, so it stays conservative: duck rather than pause.
            if LiveContext.isActive() {
                return Scene(appsToPause: [], pauseTargets: [], hasLiveAudio: outputActive,
                             duckRemainingMedia: false)
            }
            // Without per-process truth this path knows only that *something*
            // is driving the output. That was enough to fire a blind media
            // key; it is not enough to be sure anything is audible, so duck.
            return Scene(appsToPause: [], pauseTargets: [], hasLiveAudio: false,
                         duckRemainingMedia: outputActive)
        }

        /// Are any of these identities still producing output?
        static func stillPlaying(_ identities: Set<String>) -> Bool {
            let processes = SystemAudio.processes()
            guard !processes.isEmpty else { return false }
            return processes.contains { $0.isPlaying && identities.contains($0.identity) }
        }
    }

    // MARK: - Helpers

    private static func isAppRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Fire-and-forget Apple Event, dispatched to the main thread.
    ///
    /// NSAppleScript is documented as main-thread-only, and a synchronous
    /// inter-app event needs a run loop for its reply — so this stays on main.
    /// Async, though: the audio queue never waits for a busy Spotify, and unlike
    /// the previous implementation it only fires when CoreAudio has already
    /// confirmed the player is actually producing sound.
    private static func run(_ source: String) {
        DispatchQueue.main.async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error { NSLog("[Haynoi] AppleScript failed: %@", error) }
        }
    }

}
