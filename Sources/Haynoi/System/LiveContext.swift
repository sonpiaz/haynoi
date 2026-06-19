import AppKit

/// Shared live-context detector — true when a conferencing / streaming /
/// screen-recording app is running, i.e. contexts where interrupting the user
/// (auto-pausing media, popping a learn toast) would step on something live.
///
/// Extracted from `MediaController.isLiveContext()` (commit 5fccb8b) so the v1.1
/// "fix that" learn toast can reuse the exact same bundle-id set without
/// duplicating it. Haynoi-local on purpose — NOT moved into the shared app-kit.
enum LiveContext {
    static let liveApps: Set<String> = [
        "us.zoom.xos",                    // Zoom
        "com.microsoft.teams2",           // Microsoft Teams
        "com.microsoft.teams",
        "com.hnc.Discord",                // Discord
        "com.cisco.webexmeetingsapp",     // Webex
        "com.readdle.calls",              // (generic call apps)
        "com.obsproject.obs-studio",      // OBS (streaming/recording)
        "com.apple.screencaptureui",      // macOS screenshot/recording UI
        "com.loom.desktop",               // Loom
        "com.electron.screen-studio",     // Screen Studio
    ]

    static func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            guard let id = $0.bundleIdentifier else { return false }
            return liveApps.contains(id)
        }
    }
}
