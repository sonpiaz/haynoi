import AppKit

/// Pause/resume media playback (Spotify, Apple Music) during dictation.
enum MediaController {
    private static var pausedApp: String?

    static func pauseIfPlaying() {
        guard UserDefaults.standard.bool(forKey: "muteMusic") else { return }

        // Try Spotify
        if isAppRunning("com.spotify.client") {
            let script = "tell application \"Spotify\" to if player state is playing then pause"
            runAppleScript(script)
            pausedApp = "Spotify"
            return
        }

        // Try Apple Music
        if isAppRunning("com.apple.Music") {
            let script = "tell application \"Music\" to if player state is playing then pause"
            runAppleScript(script)
            pausedApp = "Music"
            return
        }
    }

    static func resumeIfPaused() {
        guard let app = pausedApp else { return }
        pausedApp = nil

        switch app {
        case "Spotify":
            runAppleScript("tell application \"Spotify\" to play")
        case "Music":
            runAppleScript("tell application \"Music\" to play")
        default: break
        }
    }

    private static func isAppRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private static func runAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
        }
    }
}
