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

    /// A clean human display name for a dictation's destination app, used in the
    /// history rows (board shows "Slack", "Google Calendar", "Notion", …).
    /// Prefers a curated label for well-known bundle ids, then falls back to the
    /// stored localized `appName`, then a tidied bundle id.
    static func displayName(bundleId: String?, fallback: String?) -> String? {
        if let id = bundleId, let known = knownAppNames[id] {
            return known
        }
        if let name = fallback, !name.isEmpty {
            return name
        }
        guard let id = bundleId, !id.isEmpty else { return nil }
        // Tidy a reverse-dns id into its last segment, capitalized.
        let last = id.split(separator: ".").last.map(String.init) ?? id
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// Curated display names matching the founder board's source labels.
    private static let knownAppNames: [String: String] = [
        "com.tinyspeck.slackmacgap":      "Slack",
        "com.apple.iCal":                 "Calendar",
        "com.apple.iCalendar":            "Calendar",
        "com.google.Chrome":              "Chrome",
        "com.apple.Safari":               "Safari",
        "notion.id":                      "Notion",
        "com.linear":                     "Linear",
        "com.linearapp.linear":           "Linear",
        "com.apple.reminders":            "Reminders",
        "com.apple.mail":                 "Mail",
        "com.google.Gmail":               "Gmail",
        "com.microsoft.Outlook":          "Outlook",
        "com.superhuman.electron":        "Superhuman",
        "ru.keepcoder.Telegram":          "Telegram",
        "com.hnc.Discord":                "Discord",
        "com.apple.MobileSMS":            "Messages",
        "net.whatsapp.WhatsApp":          "WhatsApp",
        "us.zoom.xos":                    "Zoom",
        "com.microsoft.teams2":           "Teams",
        "com.apple.Notes":                "Notes",
        "md.obsidian":                    "Obsidian",
        "com.microsoft.VSCode":           "VS Code",
        "com.figma.Desktop":              "Figma",
    ]
}
