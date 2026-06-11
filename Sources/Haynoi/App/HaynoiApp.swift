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

// MARK: - Menu Bar Content (Mercury)

/// Mercury-styled menu bar popover — paper ground, ink text, serif name poem.
private struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var authState: AuthState
    @ObservedObject private var checker: UpdaterChecker
    @Environment(\.colorScheme) private var scheme
    private let updater: SPUUpdater

    // Balance — fetched once on appear
    @State private var creditBalance: Double? = nil
    @State private var isFetchingBalance = false

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checker = UpdaterChecker(updater: updater)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — app identity + name poem
            popoverHeader

            popoverDivider

            // Last dictation preview
            if let last = state.transcriptions.first {
                lastDictationRow(last)
                popoverDivider
            }

            // Retry / out-of-credits
            if state.hasFailedDictation && !state.isTranscribing && !state.isRecording {
                retryRow
                popoverDivider
            }

            // Credits strip
            creditsStrip

            popoverDivider

            // Actions list
            actionsSection

            popoverDivider

            // Account footer
            accountFooter
        }
        .background(Color.mercuryBackground(for: scheme))
        .onAppear { refreshBalance() }
        .onReceive(NotificationCenter.default.publisher(for: .haynoiDictationCompleted)) { _ in
            refreshBalance()
        }
    }

    // MARK: - Header

    private var popoverHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Name + tagline poem
            VStack(alignment: .leading, spacing: 2) {
                Text("Haynoi")
                    .font(.mercuryPopoverName)
                    .foregroundStyle(Color.mercuryLabel(for: scheme))

                Text("hãy nói  ·  hay nói  ·  Hà Nội")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mercuryLabel4(for: scheme))
            }

            Spacer()

            // Orb mini indicator
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(Color.auroraBlue.opacity(0.07))
                        .frame(width: 28, height: 28)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.55, green: 0.9, blue: 1.0),
                                    Color(red: 0.3, green: 0.15, blue: 0.65)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 5
                            )
                        )
                        .frame(width: 10, height: 10)
                        .shadow(color: Color.auroraCyan.opacity(0.6), radius: 3)
                }
                Text(orbStatusLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.mercuryLabel5(for: scheme))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(Color.mercuryWarm(for: scheme))
    }

    private var orbStatusLabel: String {
        if state.isRecording { return "recording" }
        if state.isTranscribing { return "thinking" }
        return "ready"
    }

    // MARK: - Last Dictation

    private func lastDictationRow(_ entry: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last dictation")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.mercuryLabel5(for: scheme))
                .kerning(0.7)
                .textCase(.uppercase)

            Text(entry.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mercuryLabel2(for: scheme))
                .lineLimit(2)

            HStack(spacing: 6) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: {
                    Text("Copy")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.mercuryLabel3(for: scheme))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.mercuryWarm(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mercuryDivider(for: scheme), lineWidth: 1))
                .help("Copy last dictation")

                if state.hasFailedDictation {
                    Button {
                        PipelineController.shared.retryLastFailedDictation()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.mercuryOrange)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.mercuryWarm(for: scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mercuryDivider(for: scheme), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.mercuryBackground(for: scheme))
    }

    // MARK: - Retry Row (out-of-credits)

    @ViewBuilder
    private var retryRow: some View {
        if isLastErrorOutOfCredits {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.mercuryOrange)
                    .font(.system(size: 11))
                Text("Add credits to continue —")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mercuryLabel3(for: scheme))
                Link("kymaapi.com", destination: URL(string: "https://kymaapi.com")!)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.auroraBlue)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.mercuryOrange.opacity(0.06))
        }
    }

    // MARK: - Credits Strip

    private var creditsStrip: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if let balance = creditBalance {
                    Text(String(format: "$%.2f", balance))
                        .font(.mercuryPopoverBalance)
                        .foregroundStyle(Color.mercuryLabel(for: scheme))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.mercuryPopoverBalance)
                        .foregroundStyle(Color.mercuryLabel5(for: scheme))
                }

                // Mini bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.mercuryMid(for: scheme))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [.auroraCyan, .auroraViolet], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * popoverBalanceFraction, height: 3)
                    }
                }
                .frame(height: 3)

                Text(popoverMinutesEstimate)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mercuryLabel4(for: scheme))
            }

            Spacer()

            Link("Top up ↗", destination: URL(string: "https://kymaapi.com")!)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.auroraBlue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.mercuryWarm(for: scheme))
    }

    private var popoverBalanceFraction: CGFloat {
        guard let b = creditBalance, b > 0 else { return 0 }
        return min(CGFloat(b) / 20.0, 1.0)
    }

    private var popoverMinutesEstimate: String {
        guard let b = creditBalance else { return "Sign in to see balance" }
        let mins = Int(b / 0.02)
        return "~\(mins) min remaining"
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 2) {
            // Open Ledger
            popoverActionRow(
                iconSystem: "list.bullet.rectangle",
                iconBg: Color.auroraBlue.opacity(0.12),
                iconFg: Color.auroraBlue,
                label: "Open Ledger",
                sub: "View your full dictation history",
                trailing: "⌘O"
            ) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(#selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)),
                                 to: nil, from: nil)
            }

            // Mode indicator
            popoverActionRow(
                iconSystem: "square.grid.2x2",
                iconBg: Color.mercuryMid(for: scheme),
                iconFg: Color.mercuryLabel3(for: scheme),
                label: "Mode: \(TranscriptionMode.current.rawValue)",
                sub: TranscriptionMode.current.shortDescription,
                trailing: nil
            ) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            // Check for updates
            popoverActionRow(
                iconSystem: "arrow.clockwise",
                iconBg: Color.mercuryMid(for: scheme),
                iconFg: Color.mercuryLabel3(for: scheme),
                label: "Check for updates",
                sub: "Powered by Kyma",
                trailing: nil
            ) {
                updater.checkForUpdates()
            }
            .disabled(!checker.canCheckForUpdates)

            // Settings
            popoverActionRow(
                iconSystem: "gear",
                iconBg: Color.mercuryMid(for: scheme),
                iconFg: Color.mercuryLabel3(for: scheme),
                label: "Settings",
                sub: "Hotkey, sound, language",
                trailing: "⌘,"
            ) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.mercuryBackground(for: scheme))
    }

    @ViewBuilder
    private func popoverActionRow(
        iconSystem: String,
        iconBg: Color,
        iconFg: Color,
        label: String,
        sub: String,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(iconBg)
                        .frame(width: 28, height: 28)
                    Image(systemName: iconSystem)
                        .font(.system(size: 13))
                        .foregroundStyle(iconFg)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mercuryLabel2(for: scheme))
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mercuryLabel5(for: scheme))
                }

                Spacer()

                if let key = trailing {
                    Text(key)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mercuryLabel5(for: scheme))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.mercuryMid(for: scheme), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.mercuryDivider(for: scheme), lineWidth: 1))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        .onHover { h in /* hover highlight handled by button */ _ = h }
    }

    // MARK: - Account Footer

    private var accountFooter: some View {
        HStack(spacing: 10) {
            // Avatar + email chip
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.auroraViolet, .auroraCyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 24, height: 24)
                    Text(avatarInitial)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }

                if let email = authState.signedInEmail {
                    Text(shortenEmail(email))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mercuryLabel4(for: scheme))
                        .lineLimit(1)
                } else {
                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text("Sign in")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.auroraBlue)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Settings
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.mercuryLabel4(for: scheme))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(Color.mercuryMid(for: scheme).opacity(0), in: RoundedRectangle(cornerRadius: 6))
            .help("Open Settings")

            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.mercuryLabel4(for: scheme))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help("Quit Haynoi")
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.mercuryWarm(for: scheme))
    }

    // MARK: - Helpers

    private var avatarInitial: String {
        authState.signedInEmail?.first.map(String.init)?.uppercased() ?? "H"
    }

    private func shortenEmail(_ email: String) -> String {
        guard email.count > 20 else { return email }
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return email }
        let user = parts[0].prefix(4) + "…"
        return "\(user)@\(parts[1])"
    }

    private var isLastErrorOutOfCredits: Bool {
        guard let err = state.error else { return false }
        return err.contains("credits") || err.contains("credit")
    }

    private var popoverDivider: some View {
        Rectangle()
            .fill(Color.mercuryDivider(for: scheme))
            .frame(height: 1)
    }

    private func refreshBalance() {
        guard let apiKey = KymaAuth.currentApiKey else { return }
        guard !isFetchingBalance else { return }
        isFetchingBalance = true
        Task { @MainActor in
            defer { isFetchingBalance = false }
            do {
                var req = URLRequest(url: URL(string: "https://api.kymaapi.com/v1/credits/balance")!)
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let balance = json["balance"] as? Double else { return }
                creditBalance = balance
            } catch {
                NSLog("[Haynoi] Popover balance: %@", error.localizedDescription)
            }
        }
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

// MARK: - Onboarding Window

/// Custom NSWindow subclass that handles the close button mid-onboarding.
/// Closing onboarding early counts as done: the main window always opens so
/// the app is never invisible, and Settings → General → Restart Setup… (plus
/// the Permissions tab) covers anyone who bailed before granting access.
final class OnboardingWindow: NSWindow {
    override func close() {
        let completed = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if !completed {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            NSLog("[Haynoi] Onboarding closed early — marked done; Restart Setup remains available")
        }
        super.close()
        // Ensure the main window opens so the app isn't left with no visible UI
        DispatchQueue.main.async {
            AppDelegate.shared?.showMainWindowPublic()
        }
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

        // Observe "Restart Setup…" from the Settings General tab
        NotificationCenter.default.addObserver(
            forName: .haynoiRestartSetup,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showOnboarding()
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
            .frame(minWidth: 680, minHeight: 480)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
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
        // Close any existing onboarding window before showing a fresh one
        onboardingWindow?.close()
        onboardingWindow = nil

        let view = OnboardingView {
            DispatchQueue.main.async { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.showMainWindowPublic()
            }
        }

        let window = OnboardingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Hidden titlebar: window chrome present (draggable) but no visible title bar text
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }
}
