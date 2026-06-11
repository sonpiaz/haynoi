import Sparkle
import SwiftUI
import UserNotifications

@main
struct HaynoiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var authState = AuthState.shared

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(updater: updaterController.updater)
                .environmentObject(appState)
                .environmentObject(authState)
                .frame(width: 360)
        } label: {
            Label("Haynoi", systemImage: appState.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Menu Bar Content

/// Full-height menu bar popover: history list on top, control footer on bottom.
private struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var authState: AuthState
    @ObservedObject private var checker: UpdaterChecker
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checker = UpdaterChecker(updater: updater)
    }

    var body: some View {
        VStack(spacing: 0) {
            // History list — scrollable, fills available space
            ContentView()
                .environmentObject(state)
                .frame(minHeight: 280, maxHeight: 400)

            Divider()
            menuFooter
        }
    }

    // MARK: - Footer

    private var menuFooter: some View {
        VStack(spacing: 0) {
            // Retry / out-of-credits row
            if state.hasFailedDictation && !state.isTranscribing && !state.isRecording {
                retryRow
                Divider()
            }

            // Account chip + gear + open + quit
            HStack(spacing: 0) {
                accountChip
                Spacer(minLength: 0)
                footerActions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private var retryRow: some View {
        let isOutOfCredits = isLastErrorOutOfCredits
        Button {
            if !isOutOfCredits {
                PipelineController.shared.retryLastFailedDictation()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOutOfCredits
                      ? "exclamationmark.circle.fill"
                      : "arrow.clockwise.circle.fill")
                    .foregroundStyle(isOutOfCredits ? .orange : .orange)
                    .font(.caption)

                if isOutOfCredits {
                    Text("Add credits first")
                        .font(.caption).foregroundStyle(.orange)
                    Link("kymaapi.com",
                         destination: URL(string: "https://kymaapi.com")!)
                        .font(.caption)
                } else {
                    Text("Retry Last Dictation")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(isOutOfCredits)
        .background(Color.orange.opacity(0.08))
    }

    private var accountChip: some View {
        Group {
            if let email = authState.signedInEmail {
                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle")
                            .font(.caption)
                        Text("Sign in")
                            .font(.caption)
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footerActions: some View {
        HStack(spacing: 2) {
            // Check for updates
            Button {
                updater.checkForUpdates()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Check for Updates")
            .disabled(!checker.canCheckForUpdates)

            // Settings
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Settings")
            .keyboardShortcut(",", modifiers: .command)

            // Open main window
            Button {
                // Activate app and open main window via standard reopen mechanism
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(#selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)),
                                 to: nil, from: nil)
            } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Haynoi")

            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Haynoi (⌘Q)")
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    // MARK: - Helpers

    private var isLastErrorOutOfCredits: Bool {
        guard let err = state.error else { return false }
        return err.contains("credits") || err.contains("credit")
    }
}

// MARK: - Sparkle Checker

private final class UpdaterChecker: ObservableObject {
    @Published var canCheckForUpdates = false
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var shared: AppDelegate?

    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        UserDefaults.standard.register(defaults: ["soundEnabled": true])
        NSLog("[Haynoi] App launched")
        NSApplication.shared.setActivationPolicy(.regular)

        let choice = UserDefaults.standard.string(forKey: "hotkeyChoice") ?? "command"
        switch choice {
        case "option": HotkeyManager.shared.targetModifier = .maskAlternate
        case "control": HotkeyManager.shared.targetModifier = .maskControl
        case "fn": HotkeyManager.shared.targetModifier = .maskSecondaryFn
        default: HotkeyManager.shared.targetModifier = .maskCommand
        }

        PipelineController.shared.setup()

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            NSLog("[Haynoi] Notification permission: %@", granted ? "granted" : "denied")
        }

        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            showOnboarding()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.notification.request.content.userInfo["action"] as? String
        NSLog("[Haynoi] Notification action: %@", action ?? "none")

        switch action {
        case "retryLastDictation":
            Task { @MainActor in
                PipelineController.shared.retryLastFailedDictation()
            }
        case "openMicSettings":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case "openSettings":
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        default:
            break
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindowPublic()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Windows (public so menu bar footer can call it)

    func showMainWindowPublic() {
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

    private func showOnboarding() {
        let view = OnboardingView {
            DispatchQueue.main.async { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.showMainWindowPublic()
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
}
