import AppKit

/// Detects the frontmost app and suggests a transcription style.
/// Maps app bundle IDs to styles for automatic mode switching.
enum AppStyleDetector {
    /// Returns the appropriate TranscriptionMode based on the active app.
    /// Only active when user sets mode to "Auto".
    static func detectMode() -> TranscriptionMode {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return .normal
        }

        // Email apps → formal
        if isEmailApp(bundleID) { return .email }

        // Chat/messaging → clean (remove filler words)
        if isChatApp(bundleID) { return .clean }

        // Default
        return .normal
    }

    private static func isEmailApp(_ id: String) -> Bool {
        let emailApps = [
            "com.apple.mail",
            "com.google.Gmail",
            "com.microsoft.Outlook",
            "com.readdle.smartemail",
            "com.superhuman.electron",
        ]
        return emailApps.contains(id)
    }

    private static func isChatApp(_ id: String) -> Bool {
        let chatApps = [
            "com.tinyspeck.slackmacgap",  // Slack
            "com.facebook.archon",          // Messenger
            "net.whatsapp.WhatsApp",
            "com.apple.MobileSMS",          // Messages
            "ru.keepcoder.Telegram",        // Telegram
            "com.hnc.Discord",
            "us.zoom.xos",
            "com.microsoft.teams2",
        ]
        return chatApps.contains(id)
    }
}
