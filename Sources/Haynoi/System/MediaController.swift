import AppKit

/// Pause/resume media playback during dictation.
///
/// Two tiers:
///  1. Scriptable players (Spotify, Apple Music) → AppleScript pause/play.
///     Clean: resumes from the exact position, no toggle ambiguity.
///  2. Everything else (YouTube/browser video, Podcasts, VLC, games…) →
///     the system Play/Pause media key, sent only when neither scriptable
///     player is running (so we never accidentally start a paused Spotify).
enum MediaController {
    private static var pausedApp: String?
    private static var didSendMediaKey = false

    static func pauseIfPlaying() {
        guard UserDefaults.standard.bool(forKey: "muteMusic") else { return }

        // Tier 1 — Spotify.
        if isAppRunning("com.spotify.client") {
            if isPlaying("Spotify") {
                runAppleScript("tell application \"Spotify\" to pause")
                pausedApp = "Spotify"
            }
            return // Spotify present → don't risk the media key toggling it
        }

        // Tier 1 — Apple Music.
        if isAppRunning("com.apple.Music") {
            if isPlaying("Music") {
                runAppleScript("tell application \"Music\" to pause")
                pausedApp = "Music"
            }
            return
        }

        // Tier 2 — neither scriptable player running → safe to use the media
        // key for whatever is playing (browser video, podcast, etc.).
        sendPlayPauseKey()
        didSendMediaKey = true
    }

    static func resumeIfPaused() {
        if let app = pausedApp {
            pausedApp = nil
            runAppleScript("tell application \"\(app)\" to play")
            return
        }
        if didSendMediaKey {
            didSendMediaKey = false
            sendPlayPauseKey() // symmetric toggle back to playing
        }
    }

    // MARK: - Helpers

    private static func isAppRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Whether a scriptable player reports `player state is playing`.
    private static func isPlaying(_ app: String) -> Bool {
        guard let script = NSAppleScript(source: "tell application \"\(app)\" to player state is playing") else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    private static func runAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }

    /// Post the system-defined Play/Pause media key (NX_KEYTYPE_PLAY = 16).
    /// Pauses/resumes whatever currently holds the system "now playing" target
    /// (browser video, Podcasts, VLC, …) without touching output volume, so
    /// Haynoi's own start/stop chord stays audible.
    private static func sendPlayPauseKey() {
        func post(_ keyDown: Bool) {
            let rawFlags = keyDown ? 0xA00 : 0xB00
            let data1 = (16 << 16) | ((keyDown ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(rawFlags)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true)
        post(false)
    }
}
