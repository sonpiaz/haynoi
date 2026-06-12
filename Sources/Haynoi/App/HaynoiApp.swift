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

// MARK: - Menu Bar Content (Calm)

/// Calm-styled menu bar popover — the most-used consumer surface.
/// Layout per the approved board: aurora orb + status, hold-key chips,
/// indigo record button, last dictation, aurora credit-balance bar, footer.
private struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var authState: AuthState
    @ObservedObject private var checker: UpdaterChecker
    @ObservedObject private var balanceManager = BalanceManager.shared
    @Environment(\.colorScheme) private var scheme
    @AppStorage("hotkeyChoice") private var hotkeyChoice = "command"
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checker = UpdaterChecker(updater: updater)
    }

    private var status: CalmStatus {
        if state.isRecording { return .recording }
        if state.isTranscribing { return .transcribing }
        if state.hasFailedDictation && !isLastErrorOutOfCredits { return .error }
        return .idle
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header — aurora orb + app identity + live status
                popoverHeader

                popoverDivider

                // Hold-to-dictate hotkey chips
                hotkeySection

                popoverDivider

                // Standalone retry row — failed dictation, no history yet
                if state.hasFailedDictation && !state.isTranscribing && !state.isRecording
                    && !isLastErrorOutOfCredits && state.transcriptions.isEmpty {
                    standaloneRetryRow
                    popoverDivider
                }

                // Out-of-credits banner
                if state.hasFailedDictation && !state.isTranscribing && !state.isRecording {
                    retryRow
                    popoverDivider
                }

                // Last dictation preview
                if let last = state.transcriptions.first {
                    lastDictationRow(last)
                    popoverDivider
                }

                // Credit-balance bar (aurora) + actions
                creditsStrip

                popoverDivider

                // Quiet actions (ledger / mode / updates / settings)
                actionsSection

                popoverDivider

                // Account footer (account / settings / quit)
                accountFooter
            }
        }
        .frame(maxHeight: 560)
        .background(Color.calmBackground(for: scheme))
        .onAppear { BalanceManager.shared.refresh() }
    }

    // MARK: - Header (orb + identity + status)

    private var popoverHeader: some View {
        HStack(alignment: .center, spacing: 13) {
            // Aurora orb — the saturated hero motif (mirrors app icon)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [Color(hex: "#0F1220"), Color(hex: "#1A1E34")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                CalmOrbBars(active: status == .recording || status == .transcribing)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Haynoi")
                    .font(.calmPopoverName)
                    .foregroundStyle(Color.calmLabel(for: scheme))

                HStack(spacing: 6) {
                    CalmStatusDot(status: status)
                    Text(status.label)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.calmLabel3(for: scheme))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 15)
        .background(Color.calmSurface(for: scheme))
    }

    // MARK: - Hotkey chips

    private var hotkeySection: some View {
        HStack {
            Text("Hold to dictate anywhere")
                .font(.system(size: 12))
                .foregroundStyle(Color.calmLabel3(for: scheme))
            Spacer()
            HStack(spacing: 4) {
                calmKey(hotkeySymbol)
                calmKey("Space")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Color.calmSurface(for: scheme))
    }

    private func calmKey(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.calmLabel(for: scheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.calmSubtle(for: scheme), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.calmHairline(for: scheme), lineWidth: 1)
            )
    }

    private var hotkeySymbol: String {
        switch hotkeyChoice {
        case "option":  return "⌥"
        case "control": return "⌃"
        case "fn":      return "fn"
        default:        return "⌘"
        }
    }

    // MARK: - Last Dictation

    private func lastDictationRow(_ entry: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Last dictation")
                .font(.calmSectionLabel)
                .foregroundStyle(Color.calmLabel4(for: scheme))
                .kerning(0.7)
                .textCase(.uppercase)

            Text(entry.text)
                .font(.system(size: 13))
                .foregroundStyle(Color.calmLabel(for: scheme))
                .lineLimit(2)

            Text(lastMeta(entry))
                .font(.system(size: 11))
                .foregroundStyle(Color.calmLabel4(for: scheme))

            HStack(spacing: 6) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: {
                    Text("Copy again")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.calmAccent(for: scheme))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Color.calmAccentWash(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.calmAccent(for: scheme).opacity(0.12), lineWidth: 1))
                .help("Copy last dictation")

                if state.hasFailedDictation {
                    Button {
                        PipelineController.shared.retryLastFailedDictation()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.calmWarn)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Color.calmWarnBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.calmWarn.opacity(0.2), lineWidth: 1))
                }
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.calmSurface(for: scheme))
    }

    private func lastMeta(_ entry: Transcription) -> String {
        let mins = Int(Date().timeIntervalSince(entry.timestamp) / 60)
        let when: String
        switch mins {
        case ..<1:   when = "Just now"
        case 1:      when = "1 min ago"
        case 2..<60: when = "\(mins) min ago"
        default:     when = "\(mins / 60)h ago"
        }
        return "\(when)  ·  \(entry.wordCount) words"
    }

    // MARK: - Standalone Retry Row (empty history, transient failure)

    /// Shown when the first-ever dictation fails transiently — before any history
    /// entry exists, so the in-row retry inside lastDictationRow is not visible yet.
    private var standaloneRetryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(Color.calmWarn)
                .font(.system(size: 12))
            Text("Dictation failed —")
                .font(.system(size: 12))
                .foregroundStyle(Color.calmLabel3(for: scheme))
            Button {
                PipelineController.shared.retryLastFailedDictation()
            } label: {
                Text("Retry")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.calmWarn)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.calmSurface(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.calmWarn.opacity(0.25), lineWidth: 1))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.calmWarnBg)
    }

    // MARK: - Retry Row (out-of-credits)

    @ViewBuilder
    private var retryRow: some View {
        if isLastErrorOutOfCredits {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.calmWarn)
                    .font(.system(size: 12))
                Text("Add credits to continue —")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmLabel3(for: scheme))
                Link("kymaapi.com", destination: URL(string: "https://kymaapi.com")!)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmAccent(for: scheme))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Color.calmWarnBg)
        }
    }

    // MARK: - Credits Strip (aurora balance bar + actions)

    private var creditsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Balance value + label
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let balance = balanceManager.balance {
                    Text(String(format: "$%.2f", balance))
                        .font(.calmPopoverBalance)
                        .foregroundStyle(Color.calmLabel(for: scheme))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.calmPopoverBalance)
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
                Text("pay as you go  ·  powered by Kyma")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                Spacer()
            }

            // Aurora balance bar — the ONLY saturated element down here
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.calmHairline(for: scheme))
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient.calmAuroraBar)
                        .frame(width: geo.size.width * popoverBalanceFraction, height: 3)
                }
            }
            .frame(height: 3)

            // Actions — History / Add funds / appearance
            HStack(spacing: 6) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(#selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)),
                                     to: nil, from: nil)
                } label: {
                    Text("History")
                        .calmFooterChip(scheme)
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: "https://kymaapi.com")!) {
                    Text("Add funds")
                        .calmFooterChip(scheme)
                }

                Spacer()

                Text(popoverMinutesEstimate)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Color.calmSubtle(for: scheme))
    }

    private var popoverBalanceFraction: CGFloat {
        guard let b = balanceManager.balance, b > 0 else { return 0 }
        return min(CGFloat(b) / 20.0, 1.0)
    }

    private var popoverMinutesEstimate: String {
        guard let b = balanceManager.balance else { return "Sign in to see balance" }
        let mins = Int(b / 0.02)
        return "~\(mins) min remaining"
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 1) {
            // Open Ledger
            popoverActionRow(
                iconSystem: "list.bullet.rectangle",
                label: "Open Ledger",
                sub: "Your full dictation history",
                trailing: "⌘O"
            ) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(#selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)),
                                 to: nil, from: nil)
            }

            // Mode indicator
            popoverActionRow(
                iconSystem: "square.grid.2x2",
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
                label: "Settings",
                sub: "Hotkey, sound, language",
                trailing: "⌘,"
            ) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(Color.calmBackground(for: scheme))
    }

    @ViewBuilder
    private func popoverActionRow(
        iconSystem: String,
        label: String,
        sub: String,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.calmSubtle(for: scheme))
                        .frame(width: 28, height: 28)
                    Image(systemName: iconSystem)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.calmLabel3(for: scheme))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.calmLabel(for: scheme))
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }

                Spacer()

                if let key = trailing {
                    Text(key)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.calmSubtle(for: scheme), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.calmHairline(for: scheme), lineWidth: 1))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
    }

    // MARK: - Account Footer

    private var accountFooter: some View {
        HStack(spacing: 10) {
            // Avatar + email chip — aurora avatar is a sanctioned aurora moment
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.calmAuroraCyan, .calmAuroraViolet], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 24, height: 24)
                    Text(avatarInitial)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }

                if let email = authState.signedInEmail {
                    Text(shortenEmail(email))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel3(for: scheme))
                        .lineLimit(1)
                } else {
                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Text("Sign in")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.calmAccent(for: scheme))
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
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help("Open Settings")

            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .help("Quit Haynoi")
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.calmSubtle(for: scheme))
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
            .fill(Color.calmDivider(for: scheme))
            .frame(height: 1)
    }

}

// MARK: - Calm footer chip style

private extension Text {
    /// Quiet outlined chip used for History / Add funds in the credit strip.
    func calmFooterChip(_ scheme: ColorScheme) -> some View {
        self
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.calmLabel3(for: scheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.calmSurface(for: scheme), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.calmBorder, lineWidth: 1))
    }
}

// MARK: - Calm Orb Bars (popover header micro-waveform)

/// The aurora micro-waveform that sits inside the dark popover orb tile.
/// Mirrors the board's three-bar orb. Saturated aurora gradient is sanctioned
/// here — the orb is one of the four approved aurora surfaces.
private struct CalmOrbBars: View {
    let active: Bool
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(LinearGradient(
                        colors: [.calmAuroraCyan, .calmAuroraViolet, .calmAuroraPink],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .frame(height: 18)
        .onAppear {
            guard active else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base: [CGFloat] = [10, 16, 8]
        guard active else { return base[i] * 0.6 }
        let wobble = sin(Double(i) * 1.3 + phase * .pi) * 4
        return base[i] + CGFloat(wobble)
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

        // Stateless resume (D2): start at the first unsatisfied step from live state.
        let resumeStep = OnboardingView.resumeStep()

        let view = OnboardingView(initialStep: resumeStep) {
            DispatchQueue.main.async { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                self?.showMainWindowPublic()
            }
        }

        // Size the window for the resume step: the Input Monitoring /
        // Accessibility split-screen teaching steps are wide (Onboarding v3).
        let initialSize = resumeStep.isWide
            ? NSSize(width: 920, height: 600)
            : NSSize(width: 460, height: 580)

        let window = OnboardingWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
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
