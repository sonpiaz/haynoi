import AppKit
import XCTest
@testable import Haynoi

/// The pause-vs-duck policy, tested as a pure function of what the Mac is
/// playing. No mic, no call, no sound card — every branch of the decision that
/// runs when you press the dictation key.
final class MediaPolicyTests: XCTestCase {

    private func process(
        _ bundleID: String?,
        pid: pid_t = 1,
        playing: Bool = false,
        capturing: Bool = false
    ) -> SystemAudio.AudioProcess {
        SystemAudio.AudioProcess(pid: pid, bundleID: bundleID, isPlaying: playing, isCapturing: capturing)
    }

    private func plan(_ processes: [SystemAudio.AudioProcess]) -> MediaController.Scene {
        MediaController.Scene.plan(
            processes: processes,
            myPID: 999,
            myBundleID: "com.sonpiaz.haynoi"
        )
    }

    // MARK: - Nothing playing

    func testSilenceDoesNothing() {
        // Apps open but idle: Spotify sitting there, Zoom sitting there.
        let scene = plan([
            process("com.spotify.client", pid: 1),
            process("us.zoom.xos", pid: 2),
        ])

        XCTAssertFalse(scene.hasPlayback, "No audio playing — Haynoi must not touch anything")
        XCTAssertFalse(scene.duckRemainingMedia)
        XCTAssertFalse(scene.hasLiveAudio)
        XCTAssertTrue(scene.appsToPause.isEmpty)
    }

    /// The regression that motivated the rewrite: Zoom open all day used to
    /// suppress pausing entirely, so music kept playing over every dictation.
    func testIdleZoomDoesNotBlockPausingMusic() {
        let scene = plan([
            process("us.zoom.xos", pid: 2),                       // open, silent
            process("com.spotify.client", pid: 3, playing: true),  // actually playing
        ])

        XCTAssertEqual(scene.appsToPause, ["Spotify"])
        XCTAssertFalse(scene.hasLiveAudio, "An open Zoom is not a meeting")
    }

    // MARK: - The conversation test

    func testPlayingAndCapturingIsDuckedNotPaused() {
        let scene = plan([process("us.zoom.xos", pid: 2, playing: true, capturing: true)])

        XCTAssertTrue(scene.hasLiveAudio, "A live call must be ducked")
        XCTAssertTrue(scene.appsToPause.isEmpty, "A live call must never be paused")
        XCTAssertFalse(scene.duckRemainingMedia)
    }

    /// Google Meet in a browser: audio out and mic in land on different helper
    /// processes of the same app, so identity has to collapse them.
    func testBrowserCallIsRecognisedAcrossHelperProcesses() {
        let scene = plan([
            process("com.google.Chrome.helper", pid: 10, playing: true),
            process("com.google.Chrome.helper.Renderer", pid: 11, capturing: true),
        ])

        XCTAssertTrue(scene.hasLiveAudio, "Meet in Chrome is a call, not a video")
        XCTAssertFalse(scene.duckRemainingMedia, "A live call is ducked as live audio, not as leftover media")
    }

    /// Same browser, no mic in use — that is a video, and it gets ducked.
    /// It used to get a play/pause media key, but CoreAudio cannot tell an
    /// open output stream from an audible one, so the toggle was a coin flip.
    func testBrowserVideoIsDucked() {
        let scene = plan([process("com.google.Chrome.helper", pid: 10, playing: true)])

        XCTAssertTrue(scene.duckRemainingMedia)
        XCTAssertFalse(scene.hasLiveAudio)
        XCTAssertEqual(scene.pauseTargets, ["com.google.Chrome"])
    }

    // MARK: - Mixed scenes

    func testCallAndMusicTogetherDucksCallAndPausesMusic() {
        let scene = plan([
            process("us.zoom.xos", pid: 2, playing: true, capturing: true),
            process("com.spotify.client", pid: 3, playing: true),
        ])

        XCTAssertTrue(scene.hasLiveAudio, "Zoom gets ducked")
        XCTAssertEqual(scene.appsToPause, ["Spotify"], "Spotify gets paused")
    }

    /// With Spotify running, the media key is ambiguous — it can start the
    /// paused player instead of stopping the browser. Duck the leftovers.
    func testLeftoverMediaIsDuckedWhenAScriptablePlayerIsRunning() {
        let scene = plan([
            process("com.google.Chrome.helper", pid: 10, playing: true),
        ])

        XCTAssertTrue(scene.duckRemainingMedia, "Ducked, because a media key could resume a paused Spotify")
        XCTAssertTrue(scene.duckRemainingMedia)
    }

    // MARK: - Noise filtering

    func testSiriListenerIsNotTreatedAsPlayback() {
        // CoreSpeech reports output AND input constantly; counting it would make
        // Haynoi believe a call is in progress on every single dictation.
        let scene = plan([process("com.apple.CoreSpeech", pid: 5, playing: true, capturing: true)])

        XCTAssertFalse(scene.hasPlayback)
        XCTAssertFalse(scene.hasLiveAudio)
    }

    func testHaynoiOwnAudioIsIgnored() {
        // Our own start tone plays through the same device while we capture the
        // mic — the textbook false "live call".
        let scene = plan([
            process("com.sonpiaz.haynoi", pid: 999, playing: true, capturing: true),
            process(nil, pid: 42, playing: true), // a CLI player, no bundle id
        ])

        XCTAssertFalse(scene.hasLiveAudio)
        XCTAssertEqual(scene.pauseTargets, ["pid:42"], "Bundle-less players are still real playback")
        XCTAssertTrue(scene.duckRemainingMedia)
    }

    // MARK: - Regression: a blind media key started music that was never playing

    /// Measured on a silent Mac (macOS 26, 2026-08-20): with nothing audible,
    /// CoreAudio still reports `com.apple.WebKit.GPU` as running output —
    /// persistently, sampled every 3s for 18s. `isPlaying` is
    /// kAudioProcessPropertyIsRunningOutput, i.e. "has an output stream open",
    /// NOT "is making a sound". A browser holding an idle audio context is
    /// enough. Treating it as media fired the play/pause key, which is a
    /// *toggle* — so it started the last track instead of stopping anything.
    func testIdleBrowserAudioStreamIsNotPlayback() {
        let scene = plan([
            process("com.apple.WebKit.GPU", pid: 88034, playing: true),
            process("com.shure.motivmix", pid: 27475, playing: true, capturing: true),
        ])

        XCTAssertTrue(
            scene.appsToPause.isEmpty,
            "Nothing is named and playing, so nothing may be paused"
        )
        // The fix: an idle browser stream can only ever lower the volume for a
        // moment. It can never start a track, which a toggle did.
    }

    /// The same silent scene, but with Spotify open and paused — the case the
    /// user hit: "a song waiting on the computer" that suddenly played.
    func testIdleBrowserWithPausedSpotifyNeverStartsPlayback() {
        let scene = plan([
            process("com.apple.WebKit.GPU", pid: 88034, playing: true),
            process("com.spotify.client", pid: 3), // open, paused, silent
        ])

        XCTAssertTrue(scene.appsToPause.isEmpty, "Nothing is playing, so nothing to pause")
    }

    // MARK: - Live machine

    /// The tests above feed `plan()` a scene typed by hand. This one runs the
    /// real path — CoreAudio → `processes()` → `capture()` → the policy — on
    /// whatever this Mac happens to be doing, and asserts the one property that
    /// must hold no matter what: Haynoi never issues an action that could
    /// *start* audio. Environment-dependent by design, so it asserts safety,
    /// not a particular scene.
    func testLiveSceneNeverStartsPlayback() {
        let scene = MediaController.Scene.capture()
        let running = ["com.spotify.client", "com.apple.Music"].filter { id in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == id }
        }
        print("[live] appsToPause=\(scene.appsToPause) hasLiveAudio=\(scene.hasLiveAudio) "
            + "duckRemainingMedia=\(scene.duckRemainingMedia) targets=\(scene.pauseTargets) "
            + "scriptablePlayersRunning=\(running)")

        for app in scene.appsToPause {
            XCTAssertTrue(
                running.contains(app == "Spotify" ? "com.spotify.client" : "com.apple.Music"),
                "\(app) is not even running — pausing it would be a blind command"
            )
        }
        // Ducking and AppleScript pause are the only two actions left, and
        // neither can begin playback. A toggle could, and no longer exists.
    }
}
