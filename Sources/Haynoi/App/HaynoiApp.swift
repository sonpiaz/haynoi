import Sparkle
import SwiftUI
import UserNotifications

@main
struct HaynoiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    private let updaterController: SPUStandardUpdaterController

    init() {
        // Sparkle: start updater on launch. Reads SUFeedURL + SUPublicEDKey
        // from Info.plist. Checks for updates on schedule (daily by default)
        // and exposes "Check for Updates…" menu action.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appState)
                .frame(width: 360, height: 400)
            Divider()
            CheckForUpdatesView(updater: updaterController.updater)
        } label: {
            Label("Haynoi", systemImage: appState.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// Menu item with state-driven enable/disable for Sparkle updates.
/// Disabled while an update check is in-flight; otherwise tappable.
private struct CheckForUpdatesView: View {
    @ObservedObject private var checker: UpdaterChecker
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checker = UpdaterChecker(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!checker.canCheckForUpdates)
    }
}

private final class UpdaterChecker: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["soundEnabled": true])
        NSLog("[Haynoi] App launched")
        NSApplication.shared.setActivationPolicy(.regular)

        // Apply saved hotkey
        let choice = UserDefaults.standard.string(forKey: "hotkeyChoice") ?? "command"
        switch choice {
        case "option": HotkeyManager.shared.targetModifier = .maskAlternate
        case "control": HotkeyManager.shared.targetModifier = .maskControl
        case "fn": HotkeyManager.shared.targetModifier = .maskSecondaryFn
        default: HotkeyManager.shared.targetModifier = .maskCommand
        }

        PipelineController.shared.setup()

        // Request notification permission (for insertion fallback + failure alerts)
        // Register as delegate so notification clicks are routed here.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            NSLog("[Haynoi] Notification permission: %@", granted ? "granted" : "denied")
        }

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            showOnboarding()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate (Fix #2)

    /// Called when the user clicks a Haynoi notification while the app is running.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.notification.request.content.userInfo["action"] as? String
        NSLog("[Haynoi] Notification action: %@", action ?? "none")

        switch action {
        case "retryLastDictation":
            // User tapped "Couldn't transcribe — recording saved. Click to retry."
            Task { @MainActor in
                PipelineController.shared.retryLastFailedDictation()
            }
        case "openMicSettings":
            // User tapped the mic-revoked notification — deep-link to prefs
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
        completionHandler()
    }

    /// Allow notifications to appear as banners while Haynoi is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Click dock icon → open main window
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showOnboarding() {
        let view = OnboardingView {
            // Dismiss onboarding → open main window
            DispatchQueue.main.async { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.showMainWindow()
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Haynoi"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func showMainWindow() {
        if let window = mainWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = MainView()
            .environmentObject(AppState.shared)
            .frame(minWidth: 500, minHeight: 450)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Haynoi"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
    }
}
