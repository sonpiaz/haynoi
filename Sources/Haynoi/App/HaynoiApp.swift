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
                .haynoiTheme()
        } label: {
            Label("Haynoi", systemImage: appState.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .haynoiTheme()
        }
    }
}

// MARK: - Menu Bar Content (Calm)

/// Reports the popover content's natural height up to MenuBarContent so the
/// MenuBarExtra window gets a real frame (see popoverHeight).
private struct PopoverHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One recent-dictation row in the popover: two-line text + meta, with the
/// copy icon at the RIGHT of the row (founder feedback 2026-06-12).
private struct PopoverRecentRow: View {
    let entry: Transcription
    let scheme: ColorScheme
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.calmLabel(for: scheme))
                    .lineLimit(2)
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Color.calmSuccess : Color.calmLabel4(for: scheme))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    private var meta: String {
        let mins = Int(Date().timeIntervalSince(entry.timestamp) / 60)
        let when: String
        switch mins {
        case ..<1:   when = "Just now"
        case 1:      when = "1 min ago"
        case 2..<60: when = "\(mins) min ago"
        default:     when = "\(mins / 60)h ago"
        }
        var meta = "\(when)  ·  \(entry.wordCount) words"
        if let source = AppStyleDetector.displayName(bundleId: entry.appBundleId, fallback: entry.appName) {
            meta += "  ·  \(source)"
        }
        return meta
    }
}

/// Calm-styled menu bar popover — the most-used consumer surface.
/// Layout per the approved board: aurora orb + status, hold-key chips,
/// indigo record button, last dictation, aurora credit-balance bar, footer.
private struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var authState: AuthState
    @ObservedObject private var checker: UpdaterChecker
    @ObservedObject private var balanceManager = BalanceManager.shared
    @Environment(\.colorScheme) private var scheme
    @AppStorage("hotkeyChoice") private var hotkeyChoice = "option"
    @AppStorage("languageHint") private var languageHint = "auto"
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

                // Language segmented control (VI / EN / Auto)
                languageRow

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

                // Recent dictations — top 5, copy at the right of each row
                if !state.transcriptions.isEmpty {
                    recentSection
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
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PopoverHeightKey.self, value: geo.size.height)
                }
            )
        }
        .onPreferenceChange(PopoverHeightKey.self) { popoverHeight = $0 }
        .frame(height: popoverHeight > 0 ? min(popoverHeight, 560) : 560)
        .background(Color.calmBackground(for: scheme))
        .onAppear { BalanceManager.shared.refresh() }
    }

    /// Measured height of the popover content. A bare ScrollView has no
    /// intrinsic height, so inside the MenuBarExtra window it collapsed to
    /// ~10pt — the popover opened invisibly (live bug 2026-06-12). We measure
    /// the real content height and pin the frame to it, capped at 560.
    @State private var popoverHeight: CGFloat = 0

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
                CalmOrbBars(status: status, level: state.audioLevel)
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
            HStack(spacing: 6) {
                calmKey(hotkeySymbol)
                Text(hotkeyName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmLabel3(for: scheme))
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
        case "command": return "⌘"
        case "control": return "⌃"
        case "fn":      return "fn"
        default:        return "⌥"
        }
    }

    private var hotkeyName: String {
        switch hotkeyChoice {
        case "command": return "Command"
        case "control": return "Control"
        case "fn":      return "Globe"
        default:        return "Left Option"
        }
    }

    // MARK: - Language segmented control (board panel 02)

    private var languageRow: some View {
        HStack {
            Text("Language")
                .font(.system(size: 12))
                .foregroundStyle(Color.calmLabel3(for: scheme))
            Spacer()
            HStack(spacing: 1) {
                langSegment("VI", value: "vi")
                langSegment("EN", value: "en")
                langSegment("Auto", value: "auto")
            }
            .padding(2)
            .background(Color.calmSubtle(for: scheme), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.calmBorder, lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color.calmSurface(for: scheme))
    }

    private func langSegment(_ label: String, value: String) -> some View {
        let isActive = languageHint == value
        return Button {
            languageHint = value
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.calmAccent(for: scheme) : Color.calmLabel3(for: scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    isActive ? Color.calmSurface(for: scheme) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isActive ? Color.calmAccent(for: scheme).opacity(0.25) : Color.clear, lineWidth: 1)
                )
                .shadow(color: isActive ? .black.opacity(scheme == .dark ? 0 : 0.06) : .clear, radius: 1, y: 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent Dictations (top 5)

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.calmSectionLabel)
                .foregroundStyle(Color.calmLabel4(for: scheme))
                .kerning(0.7)
                .textCase(.uppercase)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(Array(state.transcriptions.prefix(5))) { entry in
                    PopoverRecentRow(entry: entry, scheme: scheme)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
        .background(Color.calmSurface(for: scheme))
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
            // Quota value + label
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if balanceManager.tier != nil {
                    Text(popoverQuotaValue)
                        .font(.calmPopoverBalance)
                        .foregroundStyle(Color.calmLabel(for: scheme))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.calmPopoverBalance)
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
                Text(popoverQuotaLabel)
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
        // Unlimited tiers (cap 0) show a full bar; free tier shows used/cap.
        guard let cap = balanceManager.wordsCap, cap > 0,
              let used = balanceManager.wordsUsed else { return 1.0 }
        return min(max(CGFloat(used) / CGFloat(cap), 0), 1.0)
    }

    /// Big number in the popover strip — words remaining (free) or "∞".
    private var popoverQuotaValue: String {
        guard let cap = balanceManager.wordsCap, cap > 0 else { return "∞" }
        if let remaining = balanceManager.wordsRemaining { return "\(remaining)" }
        return "—"
    }

    private var popoverQuotaLabel: String {
        switch balanceManager.tier {
        case "pro": return "Pro  ·  unlimited"
        case "max": return "Max  ·  unlimited"
        default:    return "words left this week"
        }
    }

    private var popoverMinutesEstimate: String {
        switch balanceManager.tier {
        case "pro", "max": return "Unlimited"
        case "free":
            if let remaining = balanceManager.wordsRemaining {
                return "\(remaining) words left"
            }
            return "2,000 words / week"
        default:
            return "Sign in to see your plan"
        }
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
                    // SettingsLink: the legacy showSettingsWindow: selector is
                    // dead on this macOS — buttons using it silently did nothing.
                    SettingsLink {
                        Text("Sign in")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.calmAccent(for: scheme))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Settings — SettingsLink (the legacy selector silently broke)
            SettingsLink {
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
///
/// Voice-reactive: in `.recording` the bar heights are driven by the live mic
/// level (same RMS signal FloatingBar uses) with fast-attack / slow-release
/// smoothing — silence sits low and still, speech rises. `.transcribing` shows
/// a calm opacity shimmer (mic is off — no height bobbing, clearly NOT voice).
/// Idle / other states render static bars.
private struct CalmOrbBars: View {
    let status: CalmStatus
    let level: Float

    // Smoothed mic level (fast attack ~50ms, slow release ~200ms at 60fps).
    @State private var displayLevel: CGFloat = 0.04
    // Calm shimmer used only while transcribing (opacity, not height).
    @State private var shimmer: Double = 0
    @State private var ticker: Timer?

    private let baseHeights: [CGFloat] = [10, 16, 8]

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
                    .opacity(barOpacity)
            }
        }
        .frame(height: 18)
        .onAppear { syncForStatus() }
        .onChange(of: status) { _, _ in syncForStatus() }
        .onChange(of: level) { _, newLevel in
            // Drive the smoother off the live level only while recording.
            guard status == .recording else { return }
            let target = max(CGFloat(newLevel), 0.04)
            let speed: CGFloat = target > displayLevel ? 0.33 : 0.085
            displayLevel += (target - displayLevel) * speed
        }
        .onDisappear { ticker?.invalidate(); ticker = nil }
    }

    /// `.recording` → voice-driven heights; everything else → static base.
    private func barHeight(_ i: Int) -> CGFloat {
        guard status == .recording else { return baseHeights[i] * 0.6 }
        let minH: CGFloat = 4
        let maxH: CGFloat = 18
        let amp = min(max(displayLevel, 0), 1)
        // Per-bar shape so the three bars don't read as one block; amplitude is
        // entirely from the mic — at silence amp≈0.04 → bars near the floor.
        let shape: [CGFloat] = [0.7, 1.0, 0.55]
        return minH + (maxH - minH) * amp * shape[i]
    }

    /// Transcribing → gentle opacity shimmer; otherwise fully opaque.
    private var barOpacity: Double {
        status == .transcribing ? 0.45 + shimmer * 0.45 : 1.0
    }

    /// React to state changes (fixes the old onAppear-only bug): recording
    /// runs a 60fps decay ticker so the smoother keeps gliding down between
    /// level updates; transcribing runs a calm opacity shimmer; idle is still.
    private func syncForStatus() {
        ticker?.invalidate(); ticker = nil

        switch status {
        case .recording:
            // Decay ticker — eases displayLevel back toward the floor so the
            // release tail is smooth even if the mic level updates sparsely.
            shimmer = 0
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
                Task { @MainActor in
                    let floor: CGFloat = 0.04
                    if displayLevel > floor {
                        displayLevel += (floor - displayLevel) * 0.085
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer

        case .transcribing:
            // Calm pulse — opacity only, no height bobbing. Mic is off here.
            displayLevel = 0.04
            shimmer = 0
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                shimmer = 1
            }

        default:
            displayLevel = 0.04
            shimmer = 0
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
        UserDefaults.standard.register(defaults: [
            "soundEnabled": true,
            "successDinkEnabled": false, // founder feedback: 2 tones max — chip shows silently
            "soundTheme": "chime",      // founder pick: gentle bell pair (contest 2026-06-12)
            "appTheme": "light",       // founder default: white-gray light look
            "hotkeyChoice": "option",  // founder default: left Option push-to-talk
        ])
        NSLog("[Haynoi] App launched")
        // Warm the layout keycode cache on the main thread now, so the paste
        // path (which runs in a background Task) never calls TIS off-main.
        TextInserter.prewarmKeyCode()
        // Menu-bar-only by default (founder feedback 2026-06-12): no Dock icon —
        // the app lives in the menu bar like other dictation utilities. The
        // Dock icon appears only while the main/onboarding window is open
        // (see updateActivationPolicy). Dictation works as long as the app is
        // RUNNING; quitting it stops the hotkey.
        NSApplication.shared.setActivationPolicy(.accessory)

        let choice = UserDefaults.standard.string(forKey: "hotkeyChoice") ?? "option"
        switch choice {
        case "command": HotkeyManager.shared.targetModifier = .maskCommand
        case "control": HotkeyManager.shared.targetModifier = .maskControl
        case "fn": HotkeyManager.shared.targetModifier = .maskSecondaryFn
        default: HotkeyManager.shared.targetModifier = .maskAlternate
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
            // Settings can't be opened via the dead legacy selector from an
            // AppKit context — open the main window (Settings in the sidebar).
            Task { @MainActor in AppDelegate.shared?.showMainWindowPublic() }
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
        // Show the Dock icon while a real window is open (menu-bar-only otherwise).
        NSApp.setActivationPolicy(.regular)

        if let window = mainWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = MainView()
            .environmentObject(AppState.shared)
            .frame(minWidth: 680, minHeight: 480)
            .haynoiTheme()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Haynoi"
        window.appearance = Self.themeAppearance()
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow = window
        observePolicyRelevantClose(of: window)
    }

    /// Drops the Dock icon again once neither the main window nor the
    /// onboarding window is visible — the app goes back to menu-bar-only.
    private func observePolicyRelevantClose(of window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.updateActivationPolicy() }
        }
    }

    private func updateActivationPolicy() {
        let anyVisible = (mainWindow?.isVisible ?? false) || (onboardingWindow?.isVisible ?? false)
        NSApp.setActivationPolicy(anyVisible ? .regular : .accessory)
    }

    /// Maps the user's theme choice to an NSAppearance so the window chrome
    /// (titlebar + traffic lights) matches the SwiftUI content. nil follows the
    /// system. Default is the light (aqua) appearance — the founder's white-gray.
    static func themeAppearance() -> NSAppearance? {
        switch AppTheme.current {
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
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
        .haynoiTheme()

        // Size the window for the resume step: the Accessibility split-screen
        // teaching step is wide (Onboarding v3).
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
        window.appearance = Self.themeAppearance()
        window.contentView = NSHostingView(rootView: view)
        window.center()
        NSApp.setActivationPolicy(.regular) // Dock icon while onboarding is open
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
        observePolicyRelevantClose(of: window)
    }
}
