import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers

// MARK: - Onboarding v3 (Calm look — Lens C / Granola-lens)
//
// Faithful to the founder-approved board: /tmp/haynoi-ui2-calm/board.png
//   • Calm tokens only (no Mercury serif / parchment).
//   • SINGLE accent indigo for CTA + selection. The aurora gradient appears
//     only on the app-icon chip + the recording orb in the mic-test step.
//   • Split-screen SPATIAL TEACHING (Cluely pattern) for Input Monitoring +
//     Accessibility: LEFT = permission cards, RIGHT = a SwiftUI-drawn facsimile
//     of the macOS Privacy & Security pane with a synthetic cursor that
//     demonstrates flipping the exact Haynoi toggle — before the real pane
//     (still deep-linked) appears.
//   • superwhisper MIC-TEST step: live waveform that rises with the voice.
//   • superwhisper HOTKEY-TEST step: a key graphic that lights up on press.
//   • AX-TRUST-STALE fallback: if the toggle reads ON in Settings but
//     AXIsProcessTrusted()/CGPreflightListenEventAccess() still returns false
//     after ~10s, surface a "Relaunch Haynoi" button.
//
// The real drag mechanism (NSDraggingSession in BundleDragSourceView, working
// since 0.1.2) is unchanged — only re-dressed inside the calm split-screen.

// MARK: - Onboarding Step Enum

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case microphone
    case micTest
    case inputMonitoring
    case accessibility
    case hotkeyTest
    case signIn
    case tryIt

    var totalCount: Int { OnboardingStep.allCases.count }

    /// Steps that show the progress indicator (everything after Welcome).
    var showsProgress: Bool { self != .welcome }

    /// Zero-based index among the progress steps.
    var progressIndex: Int { rawValue - 1 }

    /// Whether this step uses drag-grant choreography + the wide split-screen.
    var isDragStep: Bool { self == .inputMonitoring || self == .accessibility }

    /// The wide split-screen teaching steps need a wider window.
    var isWide: Bool { isDragStep }
}

// MARK: - Drag chip state

enum DragChipState: Equatable {
    case idle
    case dragging
    case waiting
    case granted
}

// MARK: - OnboardingView

struct OnboardingView: View {
    @State private var step: OnboardingStep
    @State private var micGranted = false
    @State private var axGranted = false
    @State private var inputGranted = false
    @State private var hotkeyArmFailed = false
    @State private var pollTimer: Timer?

    // Sign-in step state
    @ObservedObject private var authState = AuthState.shared
    @State private var isSigningIn = false
    @State private var signInError = ""

    // Try It step state
    @State private var trialText = ""
    @State private var trialCelebrating = false

    // Drag-grant step state
    @State private var imChipState: DragChipState = .idle
    @State private var axChipState: DragChipState = .idle
    @State private var imFallbackVisible = false
    @State private var axFallbackVisible = false
    @State private var imFallbackTimer: Timer?
    @State private var axFallbackTimer: Timer?
    @State private var imSettingsOpenTask: DispatchWorkItem?
    @State private var axSettingsOpenTask: DispatchWorkItem?

    // AX-trust-stale fallback (the real founder bug): toggle ON in Settings but
    // the running process still reads untrusted after ~10s of polling.
    @State private var imStaleSince: Date?
    @State private var axStaleSince: Date?
    @State private var imRelaunchNudge = false
    @State private var axRelaunchNudge = false

    // Window choreography state
    @State private var windowChoreographyActive = false
    @State private var lastWindowWidth: CGFloat = 460

    var onComplete: () -> Void

    /// Designated initialiser — caller provides the starting step so that stateless
    /// resume (D2) can inject the first unsatisfied step computed from live state.
    init(initialStep: OnboardingStep = .welcome, onComplete: @escaping () -> Void) {
        _step = State(initialValue: initialStep)
        self.onComplete = onComplete
    }

    // Tracks how many transcriptions existed before Try It step began
    @State private var baselineTranscriptionCount = 0

    // Number of progress dots (steps after Welcome)
    private let progressStepCount = OnboardingStep.allCases.count - 1

    @Environment(\.colorScheme) private var scheme

    // Threshold past which a stale-grant is treated as needing relaunch.
    private static let staleGrantThreshold: TimeInterval = 10

    // MARK: - Stateless resume (D2)
    //
    // On every launch with onboarding incomplete, jump to the first unsatisfied
    // step computed from live system state — no stored step index. Diagnostic
    // steps (mic-test / hotkey-test) are skipped on resume; they only matter on a
    // fresh pass and have no system-state gate of their own.

    static func resumeStep() -> OnboardingStep {
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard micOK else { return .microphone }
        let imOK = CGPreflightListenEventAccess()
        guard imOK else { return .inputMonitoring }
        let axOK = AXIsProcessTrusted()
        guard axOK else { return .accessibility }
        let signedIn = AuthState.shared.signedInEmail != nil
        guard signedIn else { return .signIn }
        return .tryIt
    }

    var body: some View {
        Group {
            if step.isWide {
                splitScreenLayout
            } else {
                narrowLayout
            }
        }
        .frame(
            width: step.isWide ? 920 : 460,
            height: step.isWide ? 600 : 580
        )
        .background(Color.calmBackground(for: scheme))
        .onAppear {
            refreshPermissions()
            startPolling()
            applyWindowWidth(for: step)
        }
        .onDisappear {
            stopPolling()
            tearDownDragStep()
        }
        .onReceive(NotificationCenter.default.publisher(for: .haynoiDictationCompleted)) { _ in
            if step == .tryIt { handleTrialTranscription() }
        }
        .onChange(of: step) { _, newStep in
            handleStepTransition(to: newStep)
            applyWindowWidth(for: newStep)
        }
    }

    // MARK: - Narrow Layout (welcome, mic, mic-test, hotkey-test, sign-in, try-it)

    private var narrowLayout: some View {
        VStack(spacing: 0) {
            CalmHairline()

            appHeader

            progressDots
                .opacity(step.showsProgress ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: step.showsProgress)

            ZStack {
                switch step {
                case .welcome:    welcomeStep
                case .microphone: microphoneStep
                case .micTest:    micTestStep
                case .hotkeyTest: hotkeyTestStep
                case .signIn:     signInStep
                case .tryIt:      tryItStep
                default:          EmptyView()
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step.rawValue)
            .animation(.easeInOut(duration: 0.3), value: step.rawValue)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Split-Screen Layout (Cluely spatial teaching)

    private var splitScreenLayout: some View {
        HStack(spacing: 0) {
            // LEFT — permission cards + reassurance
            permissionTeachingPanel
                .frame(width: 400)
                .background(Color.calmBackground(for: scheme))

            Rectangle()
                .fill(Color.calmDivider(for: scheme))
                .frame(width: 1)

            // RIGHT — rendered macOS System Settings facsimile + synthetic cursor
            SystemSettingsFacsimile(
                highlight: step == .inputMonitoring ? .inputMonitoring : .accessibility,
                granted: step == .inputMonitoring ? inputGranted : axGranted
            )
            .frame(maxWidth: .infinity)
            .background(Color.calmSubtle(for: scheme))
        }
        .overlay(alignment: .top) { CalmHairline() }
    }

    // MARK: - Header (narrow steps)

    private var appHeader: some View {
        VStack(spacing: 12) {
            appIconBadge(size: 60)
                .padding(.top, 30)

            Text(headerTitle)
                .font(.calmTitle)
                .foregroundStyle(Color.calmLabel(for: scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.bottom, 16)
    }

    /// The app icon as a calm rounded badge with a hairline edge (no heavy shadow).
    private func appIconBadge(size: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(Color.calmHairline(for: scheme), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.08), radius: 5, y: 2)
    }

    private var headerTitle: String {
        switch step {
        case .welcome:         return "Welcome to Haynoi"
        case .microphone:      return "Allow Microphone Access"
        case .micTest:         return "Test Your Microphone"
        case .inputMonitoring: return "Two quick permissions"
        case .accessibility:   return "Two quick permissions"
        case .hotkeyTest:      return "Try Your Hotkey"
        case .signIn:          return "Connect Your Account"
        case .tryIt:           return "Try Your First Dictation"
        }
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<progressStepCount, id: \.self) { i in
                Capsule()
                    .fill(dotColor(for: i))
                    .frame(width: i == step.progressIndex ? 20 : 7, height: 7)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: step.rawValue)
            }
        }
        .padding(.bottom, 20)
    }

    private func dotColor(for i: Int) -> Color {
        guard step.showsProgress else { return Color.calmLabel5(for: scheme) }
        if i < step.progressIndex { return .calmSuccess }
        if i == step.progressIndex { return Color.calmAccent(for: scheme) }
        return Color.calmLabel5(for: scheme)
    }

    // MARK: - Step A: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Text("Haynoi lets you dictate into any app by holding \(HotkeyDisplay.symbol). Set up takes about a minute.")
                .font(.system(size: 14))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)

            calmPrimaryButton("Get Started") { advance() }
                .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step B: Microphone (standard system prompt, F1.8)

    private var microphoneStep: some View {
        permissionStepView(
            icon: "mic.fill",
            granted: micGranted,
            body: "Haynoi needs your microphone to hear your voice and convert speech to text.",
            troubleHint: "If the system prompt doesn't appear, go to System Settings → Privacy & Security → Microphone and enable Haynoi.",
            deniedURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            grantAction: {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { refreshPermissions() }
                }
            }
        )
    }

    // MARK: - Step C: Mic Test (superwhisper-style live waveform)

    private var micTestStep: some View {
        MicTestView(scheme: scheme) {
            advance()
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step D: Input Monitoring teaching panel (LEFT of split-screen)

    private var permissionTeachingPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header inside the left panel (board shows a left-aligned title)
            VStack(alignment: .leading, spacing: 6) {
                appIconBadge(size: 36)
                Text("Two quick permissions")
                    .font(.calmTitle)
                    .foregroundStyle(Color.calmLabel(for: scheme))
                Text("Haynoi needs your microphone to hear you, and the ability to type into other apps. That's it — no screen access, no files.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.calmLabel3(for: scheme))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)

            // Permission cards (states: granted / active / next)
            VStack(spacing: 10) {
                permissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "So Haynoi can hear your voice",
                    state: .granted
                )
                permissionCard(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    subtitle: "To detect your hotkey while in other apps",
                    state: cardState(for: .inputMonitoring)
                )
                permissionCard(
                    icon: "hand.raised",
                    title: "Accessibility",
                    subtitle: "To insert your spoken words into any app",
                    state: cardState(for: .accessibility)
                )
            }

            // Drag chip — the real grant mechanism, framed in the calm panel
            if !currentDragGranted {
                VStack(alignment: .center, spacing: 8) {
                    AppIconDragChipView(
                        chipState: step == .inputMonitoring ? $imChipState : $axChipState,
                        scheme: scheme,
                        onDragEnd: { resetFallbackTimer(for: step) }
                    )
                    .accessibilityLabel("Haynoi icon — drag into the System Settings list")
                    .accessibilityAction(named: "Show manual instructions") {
                        withAnimation { revealFallback(for: step) }
                    }

                    if currentChipState == .waiting {
                        Text("Now flip the switch next to Haynoi in the list →")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.calmLabel3(for: scheme))
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            }

            // AX-trust-stale relaunch nudge (real founder bug) + hotkey-arm nudge
            if currentRelaunchNudge {
                relaunchNudgeBlock
                    .padding(.top, 12)
            }

            Spacer(minLength: 8)

            // Reassurance footnote (matches board copy)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                Text("Haynoi never reads your screen, stores your audio, or accesses other apps' data. Only transcribed text is kept locally, for your history.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .background(Color.calmSubtle(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: C.rMD, style: .continuous))

            // Manual fallback toggle + reopen settings
            HStack(spacing: 12) {
                Button("Reopen System Settings") { reopenCurrentPane() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmAccent(for: scheme))
                Spacer()
                if !currentFallbackVisible {
                    Button("Having trouble?") {
                        withAnimation(.easeInOut(duration: 0.25)) { revealFallback(for: step) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                }
            }
            .padding(.top, 10)

            if currentFallbackVisible {
                fallbackBlock(instructions: currentFallbackInstructions)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    // MARK: - Step E: Hotkey Test (superwhisper-style key graphic)

    private var hotkeyTestStep: some View {
        HotkeyTestView(scheme: scheme, onContinue: { advance() })
            .padding(.horizontal, 32)
    }

    // MARK: - Step F: Sign In

    private var signInStep: some View {
        VStack(spacing: 18) {
            calmIconBadge(
                systemName: authState.signedInEmail != nil ? "checkmark.circle.fill" : "person.crop.circle.fill",
                tint: authState.signedInEmail != nil ? .calmSuccess : Color.calmAccent(for: scheme)
            )
            .animation(.easeInOut(duration: 0.2), value: authState.signedInEmail != nil)

            Text("Connect your Kyma account — free credit included. Dictation needs an account to transcribe.")
                .font(.system(size: 14))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)

            if let email = authState.signedInEmail {
                VStack(spacing: 10) {
                    Label(email, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.calmSuccess)
                    calmPrimaryButton("Continue") { advance() }
                }
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        calmPrimaryButton(isSigningIn ? "Opening browser…" : "Sign in with Kyma") { signIn() }
                            .disabled(isSigningIn)
                        if isSigningIn { ProgressView().controlSize(.small) }
                    }
                    if !signInError.isEmpty {
                        Text(signInError)
                            .font(.caption)
                            .foregroundStyle(Color.calmWarn)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                    Button("Skip for now") { advance() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step G: Try It

    private var tryItStep: some View {
        VStack(spacing: 16) {
            if trialCelebrating {
                calmIconBadge(systemName: "checkmark.circle.fill", tint: .calmSuccess)
                    .scaleEffect(trialCelebrating ? 1.06 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: trialCelebrating)
            }

            Text("Hold **\(HotkeyDisplay.symbol)** and say what you're thinking. Release to transcribe.")
                .font(.system(size: 14))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)

            // Real focusable target — a mock email/notion compose field.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color.calmAuroraPink).frame(width: 7, height: 7)
                    Circle().fill(Color.calmWarn).frame(width: 7, height: 7)
                    Circle().fill(Color.calmSuccess).frame(width: 7, height: 7)
                    Spacer()
                    Text("New message")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.calmSubtle(for: scheme))

                Divider().overlay(Color.calmDivider(for: scheme))

                TextEditor(text: $trialText)
                    .font(.system(size: 13))
                    .frame(height: 78)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.calmSurface(for: scheme))
                    .overlay(alignment: .topLeading) {
                        if trialText.isEmpty {
                            Text("Click here, then hold \(HotkeyDisplay.symbol) and speak…")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.calmLabel5(for: scheme))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: C.rMD, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: C.rMD, style: .continuous)
                    .stroke(Color.calmBorder, lineWidth: 1)
            )
            .frame(maxWidth: 360)

            VStack(spacing: 8) {
                calmPrimaryButton("Finish") {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    onComplete()
                }
                Button("Skip") {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    onComplete()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.calmLabel4(for: scheme))
            }
        }
        .padding(.horizontal, 32)
        .onAppear { baselineTranscriptionCount = AppState.shared.transcriptions.count }
    }

    // MARK: - Permission Cards (LEFT panel)

    enum CardState { case granted, active, next }

    private func cardState(for target: OnboardingStep) -> CardState {
        let granted = target == .inputMonitoring ? inputGranted : axGranted
        if granted { return .granted }
        return step == target ? .active : .next
    }

    @ViewBuilder
    private func permissionCard(icon: String, title: String, subtitle: String, state: CardState) -> some View {
        let isActive = state == .active
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(cardIconBg(state))
                    .frame(width: 32, height: 32)
                Image(systemName: state == .granted ? "checkmark" : icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(cardIconTint(state))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state == .next ? Color.calmLabel4(for: scheme) : Color.calmLabel(for: scheme))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(state == .next ? Color.calmLabel5(for: scheme) : Color.calmLabel3(for: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            switch state {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.calmSuccess)
            case .active:
                HStack(spacing: 4) {
                    Text("Allow")
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.calmAccent(for: scheme), in: Capsule())
            case .next:
                Text("Next")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel5(for: scheme))
            }
        }
        .padding(12)
        .background(isActive ? Color.calmAccentWash(for: scheme) : Color.calmSurface(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: C.rMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: C.rMD, style: .continuous)
                .stroke(isActive ? Color.calmAccent(for: scheme).opacity(0.5) : Color.calmBorder,
                        lineWidth: isActive ? 1.5 : 1)
        )
        .opacity(state == .next ? 0.7 : 1)
    }

    private func cardIconBg(_ state: CardState) -> Color {
        switch state {
        case .granted: return Color.calmSuccessBg
        case .active:  return Color.calmAccent(for: scheme).opacity(scheme == .dark ? 0.25 : 0.12)
        case .next:    return Color.calmSubtle(for: scheme)
        }
    }

    private func cardIconTint(_ state: CardState) -> Color {
        switch state {
        case .granted: return .calmSuccess
        case .active:  return Color.calmAccent(for: scheme)
        case .next:    return Color.calmLabel4(for: scheme)
        }
    }

    // MARK: - Relaunch nudge block (AX-trust-stale + hotkey-arm)

    private var relaunchNudgeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmWarn)
                Text(currentStaleNudge
                     ? "The toggle looks on, but Haynoi hasn't picked it up. A quick relaunch finishes the grant."
                     : "Haynoi needs to relaunch to activate the hotkey after granting.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.calmLabel2(for: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Relaunch Haynoi") { relaunchApp() }
                .buttonStyle(CalmButtonStyle(prominent: true, tint: .calmWarn, scheme: scheme))
        }
        .padding(11)
        .background(Color.calmWarnBg)
        .clipShape(RoundedRectangle(cornerRadius: C.rMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: C.rMD, style: .continuous)
                .stroke(Color.calmWarn.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func fallbackBlock(instructions: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual instructions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.calmLabel3(for: scheme))
            Text(instructions)
                .font(.system(size: 11))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.calmSubtle(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: C.rMD, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: C.rMD, style: .continuous)
                .stroke(Color.calmBorder, lineWidth: 1)
        )
    }

    // MARK: - Current-step accessors (split-screen)

    private var currentChipState: DragChipState {
        step == .inputMonitoring ? imChipState : axChipState
    }
    private var currentDragGranted: Bool {
        step == .inputMonitoring ? inputGranted : axGranted
    }
    private var currentFallbackVisible: Bool {
        step == .inputMonitoring ? imFallbackVisible : axFallbackVisible
    }
    private var currentRelaunchNudge: Bool {
        if step == .inputMonitoring { return imRelaunchNudge || hotkeyArmFailed }
        return axRelaunchNudge
    }
    private var currentStaleNudge: Bool {
        step == .inputMonitoring ? imRelaunchNudge : axRelaunchNudge
    }
    private var currentFallbackInstructions: String {
        step == .inputMonitoring
        ? "Open System Settings → Privacy & Security → Input Monitoring. Click +, navigate to your Applications folder, select Haynoi, then enable the toggle."
        : "Open System Settings → Privacy & Security → Accessibility. Click +, navigate to your Applications folder, select Haynoi, then enable the toggle."
    }

    private func revealFallback(for s: OnboardingStep) {
        if s == .inputMonitoring { imFallbackVisible = true } else { axFallbackVisible = true }
    }

    private func reopenCurrentPane() {
        let urlString = step == .inputMonitoring
        ? "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        reopenPane(urlString)
    }

    // MARK: - Calm primitives

    private func calmPrimaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(CalmButtonStyle(prominent: true, tint: Color.calmAccent(for: scheme), scheme: scheme))
    }

    private func calmIconBadge(systemName: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(scheme == .dark ? 0.18 : 0.10))
                .frame(width: 64, height: 64)
            Image(systemName: systemName)
                .font(.system(size: 28))
                .foregroundStyle(tint)
        }
    }

    // MARK: - Shared Permission Step Layout (Microphone only — narrow)

    @ViewBuilder
    private func permissionStepView(
        icon: String,
        granted: Bool,
        body: String,
        troubleHint: String,
        deniedURL: String,
        grantAction: @escaping () -> Void
    ) -> some View {
        let isDenied = checkDenied(for: icon)

        VStack(spacing: 16) {
            calmIconBadge(
                systemName: granted ? "checkmark.circle.fill" : icon,
                tint: granted ? .calmSuccess : Color.calmAccent(for: scheme)
            )
            .animation(.easeInOut(duration: 0.25), value: granted)

            Text(body)
                .font(.system(size: 14))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)

            if granted {
                VStack(spacing: 10) {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.calmSuccess)
                    calmPrimaryButton("Continue") { advance() }
                }
            } else if isDenied {
                VStack(spacing: 10) {
                    calmPrimaryButton("Open System Settings") {
                        if let url = URL(string: deniedURL) { NSWorkspace.shared.open(url) }
                    }
                    troubleDisclosure(hint: troubleHint)
                }
            } else {
                VStack(spacing: 10) {
                    calmPrimaryButton("Grant Access") { grantAction() }
                    troubleDisclosure(hint: troubleHint)
                }
            }
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func troubleDisclosure(hint: String) -> some View {
        DisclosureGroup("Having trouble?") {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 300)
                .padding(.top, 4)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.calmLabel4(for: scheme))
        .tint(Color.calmAccent(for: scheme))
        .frame(maxWidth: 340)
    }

    // MARK: - Navigation

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            onComplete()
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) { step = next }
    }

    // MARK: - Step Transition Choreography (F1.6, D9)

    private func handleStepTransition(to newStep: OnboardingStep) {
        if newStep.isDragStep {
            enterDragStep(newStep)
        } else {
            leaveDragStep()
        }
    }

    private func enterDragStep(_ dragStep: OnboardingStep) {
        let paneURL: String
        switch dragStep {
        case .inputMonitoring:
            paneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            imChipState = .idle
            imFallbackVisible = false
            imStaleSince = nil
            imRelaunchNudge = false
            cancelFallbackTimer(for: .inputMonitoring)
            startFallbackTimer(for: .inputMonitoring)
            imSettingsOpenTask?.cancel()
            let task = DispatchWorkItem {
                guard let url = URL(string: paneURL) else { return }
                NSWorkspace.shared.open(url)
                NSLog("[Haynoi] Onboarding: opened pane %@", paneURL)
            }
            imSettingsOpenTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
        case .accessibility:
            paneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            axChipState = .idle
            axFallbackVisible = false
            axStaleSince = nil
            axRelaunchNudge = false
            cancelFallbackTimer(for: .accessibility)
            startFallbackTimer(for: .accessibility)
            axSettingsOpenTask?.cancel()
            let task = DispatchWorkItem {
                guard let url = URL(string: paneURL) else { return }
                NSWorkspace.shared.open(url)
                NSLog("[Haynoi] Onboarding: opened pane %@", paneURL)
            }
            axSettingsOpenTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
        default:
            return
        }

        raiseWindowLevel()
    }

    private func leaveDragStep() {
        cancelFallbackTimer(for: .inputMonitoring)
        cancelFallbackTimer(for: .accessibility)
        imSettingsOpenTask?.cancel()
        axSettingsOpenTask?.cancel()
        restoreWindowLevel()
    }

    private func tearDownDragStep() { leaveDragStep() }

    // MARK: - Window Choreography (F1.6 / D9)

    private func raiseWindowLevel() {
        guard let window = findOnboardingWindow() else { return }
        window.level = .floating
        windowChoreographyActive = true
        NSLog("[Haynoi] Onboarding: window level raised for drag step")
    }

    private func restoreWindowLevel() {
        guard windowChoreographyActive, let window = findOnboardingWindow() else { return }
        window.level = .normal
        windowChoreographyActive = false
        NSLog("[Haynoi] Onboarding: window level restored after drag step")
    }

    /// Resize + recenter the onboarding window when the step changes between the
    /// narrow form and the wide split-screen teaching frame.
    private func applyWindowWidth(for s: OnboardingStep) {
        guard let window = findOnboardingWindow() else { return }
        let targetW: CGFloat = s.isWide ? 920 : 460
        let targetH: CGFloat = s.isWide ? 600 : 580
        guard abs(window.frame.width - targetW) > 1 || abs(window.frame.height - targetH) > 1 else { return }
        lastWindowWidth = targetW
        let oldFrame = window.frame
        // Keep the window centred about its current centre while resizing.
        let newX = oldFrame.midX - targetW / 2
        let newY = oldFrame.midY - targetH / 2
        let newFrame = NSRect(x: newX, y: newY, width: targetW, height: targetH)
        window.setFrame(newFrame, display: true, animate: true)
        NSLog("[Haynoi] Onboarding: window resized to %.0fx%.0f", targetW, targetH)
    }

    private func findOnboardingWindow() -> NSWindow? {
        NSApp.windows.first { $0 is OnboardingWindow }
    }

    // MARK: - Fallback Timer (D4)

    private func startFallbackTimer(for timerStep: OnboardingStep) {
        let timer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.25)) {
                    switch timerStep {
                    case .inputMonitoring: imFallbackVisible = true
                    case .accessibility:   axFallbackVisible = true
                    default: break
                    }
                }
                NSLog("[Haynoi] Onboarding: 25s fallback revealed")
            }
        }
        switch timerStep {
        case .inputMonitoring: imFallbackTimer = timer
        case .accessibility:   axFallbackTimer = timer
        default: break
        }
    }

    private func cancelFallbackTimer(for timerStep: OnboardingStep) {
        switch timerStep {
        case .inputMonitoring:
            imFallbackTimer?.invalidate(); imFallbackTimer = nil
        case .accessibility:
            axFallbackTimer?.invalidate(); axFallbackTimer = nil
        default: break
        }
    }

    private func resetFallbackTimer(for timerStep: OnboardingStep) {
        cancelFallbackTimer(for: timerStep)
        startFallbackTimer(for: timerStep)
        NSLog("[Haynoi] Onboarding: fallback timer reset after drag session ended")
    }

    // MARK: - Pane Reopen (D25)

    private func reopenPane(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
        NSLog("[Haynoi] Onboarding: re-sent pane URL %@", urlString)
    }

    // MARK: - Sign-In

    private func signIn() {
        signInError = ""
        isSigningIn = true
        Task { @MainActor in
            defer { isSigningIn = false }
            do {
                let token = try await KymaAuth.shared.signIn()
                authState.didSignIn(email: token.email)
                advance()
            } catch KymaAuth.AuthError.cancelled {
                // user dismissed — no error
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    // MARK: - Try It Transcription Observer

    private func handleTrialTranscription() {
        let newCount = AppState.shared.transcriptions.count
        guard newCount > baselineTranscriptionCount else { return }
        if let latest = AppState.shared.transcriptions.first { trialText = latest.text }
        trialCelebrating = true
        if UserDefaults.standard.bool(forKey: "soundEnabled") {
            SoundFeedback.shared.playSuccessTone()
        }
    }

    // MARK: - Relaunch

    private func relaunchApp() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("[Haynoi] relaunchApp: failed to launch — %@", error.localizedDescription)
        }
    }

    // MARK: - Permission Helpers

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Non-prompting variants (F1.7 / D3): never call CGRequestListenEventAccess()
        // or AXIsProcessTrustedWithOptions(prompt:true) on these steps.
        axGranted = AXIsProcessTrusted()
        inputGranted = CGPreflightListenEventAccess()
    }

    private func checkDenied(for icon: String) -> Bool {
        switch icon {
        case "mic.fill":
            return AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        default:
            return false
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            DispatchQueue.main.async {
                let wasInputGranted = inputGranted
                let wasAxGranted = axGranted
                refreshPermissions()

                let inputJustGranted = !wasInputGranted && inputGranted
                let axJustGranted = !wasAxGranted && axGranted

                // AX-trust-stale detection (real founder bug): we can't read the
                // System-Settings toggle directly, but if the user has spent a
                // long time on a drag step without the process flipping to
                // trusted, surface the Relaunch nudge after the threshold. The
                // chip-waiting state (drag landed, switch likely flipped) is the
                // signal that the user has acted but the process hasn't updated.
                evaluateStaleGrant(for: .inputMonitoring,
                                   granted: inputGranted,
                                   chip: imChipState,
                                   since: &imStaleSince,
                                   nudge: &imRelaunchNudge)
                evaluateStaleGrant(for: .accessibility,
                                   granted: axGranted,
                                   chip: axChipState,
                                   since: &axStaleSince,
                                   nudge: &axRelaunchNudge)

                if step == .microphone && micGranted {
                    withAnimation { advance() }
                } else if step == .inputMonitoring && inputGranted {
                    if inputJustGranted && UserDefaults.standard.bool(forKey: "soundEnabled") {
                        SoundFeedback.shared.playSuccessTone()
                    }
                    withAnimation { imChipState = .granted; imRelaunchNudge = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation { advance() }
                    }
                } else if step == .accessibility && axGranted {
                    if axJustGranted && UserDefaults.standard.bool(forKey: "soundEnabled") {
                        SoundFeedback.shared.playSuccessTone()
                    }
                    withAnimation { axChipState = .granted; axRelaunchNudge = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation { advance() }
                    }
                }

                // Arm hotkey once Input Monitoring flips to granted (preserved).
                if inputJustGranted {
                    let armed = HotkeyManager.shared.start()
                    NSLog("[Haynoi] Onboarding: hotkey arm after grant = %d", armed ? 1 : 0)
                    if !armed { hotkeyArmFailed = true }
                }
            }
        }
    }

    /// If the user has reached the "waiting" chip state (drag landed, switch
    /// likely flipped) but the process still reads not-granted after the
    /// threshold, set the relaunch nudge — the AX-trust-stale fallback.
    private func evaluateStaleGrant(
        for target: OnboardingStep,
        granted: Bool,
        chip: DragChipState,
        since: inout Date?,
        nudge: inout Bool
    ) {
        guard step == target, !granted else {
            since = nil
            return
        }
        // Only start the stale clock once the user has acted (drag landed).
        guard chip == .waiting else { return }
        if since == nil { since = Date() }
        if let start = since,
           Date().timeIntervalSince(start) >= Self.staleGrantThreshold,
           !nudge {
            withAnimation { nudge = true }
            NSLog("[Haynoi] Onboarding: AX-trust-stale nudge surfaced for %d", target.rawValue)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - Calm Button Style

/// A single restrained button style. Prominent = filled accent; otherwise a
/// hairline-bordered quiet button. No gradients, no heavy shadows.
struct CalmButtonStyle: ButtonStyle {
    var prominent: Bool = true
    var tint: Color
    var scheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(minWidth: 150)
            .background(
                RoundedRectangle(cornerRadius: C.rMD, style: .continuous)
                    .fill(prominent
                          ? tint.opacity(configuration.isPressed ? 0.85 : 1)
                          : Color.calmSurface(for: scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: C.rMD, style: .continuous)
                    .stroke(prominent ? Color.clear : Color.calmBorderMed, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - System Settings Facsimile (Cluely spatial teaching)
//
// A SwiftUI-drawn likeness of the macOS Privacy & Security pane (NOT a
// screenshot). A synthetic cursor glides to the relevant Haynoi toggle and
// "flips" it on a loop — teaching the spatial action before the real pane is in
// focus. The highlighted section (Input Monitoring / Accessibility) tracks the
// current step; once truly granted, the demo toggle settles green and the
// cursor rests.

struct SystemSettingsFacsimile: View {
    enum Highlight { case inputMonitoring, accessibility }

    let highlight: Highlight
    let granted: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var cursorAtToggle = false
    @State private var demoOn = false
    @State private var loopTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Window chrome (settings-pane traffic lights, faint)
            HStack(spacing: 7) {
                Circle().fill(Color.calmBorderStrong).frame(width: 9, height: 9)
                Circle().fill(Color.calmBorderStrong).frame(width: 9, height: 9)
                Circle().fill(Color.calmBorderStrong).frame(width: 9, height: 9)
                Spacer()
                Text("System Settings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Divider().overlay(Color.calmDivider(for: scheme))

            HStack(spacing: 0) {
                // Sidebar
                settingsSidebar
                    .frame(width: 150)
                    .background(Color.calmSubtle(for: scheme))

                Divider().overlay(Color.calmDivider(for: scheme))

                // Right pane
                settingsRightPane
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Color.calmSurface(for: scheme))
            }
        }
        .overlay(alignment: .topLeading) { syntheticCursor }
        .clipped()
        .onAppear { startLoop() }
        .onDisappear { loopTimer?.invalidate() }
        .overlay(alignment: .bottom) {
            Text("Flip the switch next to **Haynoi** — we've opened this exact page for you.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Search box
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                Text("Search")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.calmSurface(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.calmBorder, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 8)

            sidebarRow("General", icon: "gearshape", selected: false)
            sidebarRow("Appearance", icon: "paintpalette", selected: false)
            sidebarRow("Notifications", icon: "bell.badge", selected: false)
            sidebarRow("Privacy & Security", icon: "hand.raised.fill", selected: true)
            sidebarRow("Displays", icon: "display", selected: false)
            sidebarRow("Keyboard", icon: "keyboard", selected: false)
            sidebarRow("Sound", icon: "speaker.wave.2", selected: false)
            Spacer()
        }
    }

    private func sidebarRow(_ title: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .frame(width: 16)
                .foregroundStyle(selected ? .white : Color.calmLabel3(for: scheme))
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? .white : Color.calmLabel2(for: scheme))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.calmAccent(for: scheme) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 8)
    }

    private var settingsRightPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Privacy & Security")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.calmLabel(for: scheme))
                .padding(.bottom, 2)

            // MICROPHONE — always granted in the facsimile (taught earlier)
            settingsGroup(label: "MICROPHONE", highlighted: false) {
                toggleRow(app: "Haynoi", on: true, isTeachingTarget: false)
            }

            // INPUT MONITORING
            settingsGroup(label: "INPUT MONITORING",
                          highlighted: highlight == .inputMonitoring) {
                toggleRow(app: "Haynoi",
                          on: highlight == .inputMonitoring ? (granted || demoOn) : false,
                          isTeachingTarget: highlight == .inputMonitoring)
            }

            // ACCESSIBILITY
            settingsGroup(label: "ACCESSIBILITY",
                          highlighted: highlight == .accessibility) {
                VStack(spacing: 0) {
                    toggleRow(app: "Haynoi",
                              on: highlight == .accessibility ? (granted || demoOn) : false,
                              isTeachingTarget: highlight == .accessibility)
                    Divider().overlay(Color.calmDivider(for: scheme)).padding(.leading, 12)
                    toggleRow(app: "Finder", on: true, isTeachingTarget: false)
                }
            }

            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private func settingsGroup<Content: View>(
        label: String,
        highlighted: Bool,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Color.calmLabel4(for: scheme))
            VStack(spacing: 0) { content() }
                .background(
                    highlighted ? Color.calmWarnBg : Color.calmSurface(for: scheme)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(highlighted ? Color.calmWarn.opacity(0.35) : Color.calmBorder, lineWidth: 1)
                )
        }
    }

    private func toggleRow(app: String, on: Bool, isTeachingTarget: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.calmSubtle(for: scheme))
                .frame(width: 16, height: 16)
                .overlay(
                    Image(systemName: app == "Finder" ? "folder.fill" : "waveform")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                )
            Text(app)
                .font(.system(size: 12))
                .foregroundStyle(Color.calmLabel(for: scheme))
            Spacer()
            facsimileToggle(on: on, teaching: isTeachingTarget)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A drawn macOS-style toggle. On = green capsule; when it's the teaching
    /// target and the demo is flipping, it shows the indigo accent ring.
    private func facsimileToggle(on: Bool, teaching: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Color.calmSuccess : Color.calmBorderStrong)
            Circle()
                .fill(.white)
                .padding(2)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
        }
        .frame(width: 30, height: 18)
        .overlay(
            Capsule()
                .stroke(Color.calmAccent(for: scheme),
                        lineWidth: teaching && !on ? 2 : 0)
                .opacity(teaching && !on ? 1 : 0)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }

    // MARK: - Synthetic cursor

    private var syntheticCursor: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color.calmInk)
            .shadow(color: .white.opacity(0.9), radius: 0.5)
            .opacity(granted ? 0 : 1)
            // Glide between a resting spot and the teaching toggle.
            .offset(
                x: cursorAtToggle ? cursorTargetX : cursorTargetX - 80,
                y: cursorAtToggle ? cursorTargetY : cursorTargetY + 30
            )
            .animation(.easeInOut(duration: 0.9), value: cursorAtToggle)
            .allowsHitTesting(false)
    }

    // Approximate on-screen position of the teaching toggle within the facsimile.
    private var cursorTargetX: CGFloat {
        // Right pane starts at ~151pt; toggles sit near the right edge.
        highlight == .inputMonitoring ? 470 : 470
    }
    private var cursorTargetY: CGFloat {
        // Input Monitoring group sits higher than Accessibility.
        highlight == .inputMonitoring ? 195 : 270
    }

    private func startLoop() {
        guard !granted else { return }
        loopTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in
            DispatchQueue.main.async {
                withAnimation { cursorAtToggle.toggle() }
                // Flip the demo toggle a beat after the cursor arrives.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    if cursorAtToggle {
                        withAnimation { demoOn = true }
                    } else {
                        withAnimation { demoOn = false }
                    }
                }
            }
        }
    }
}

// MARK: - Mic Test (superwhisper-style live waveform)

/// Live mic level meter that rises with the voice. Static = a diagnostic with a
/// device picker + Open Settings link. Observes AppState.audioLevel, which the
/// PipelineController feeds while the mic is hot; for the test we run our own
/// short-lived recorder so the user can speak without holding the hotkey.

struct MicTestView: View {
    let scheme: ColorScheme
    let onContinue: () -> Void

    @ObservedObject private var appState = AppState.shared
    @State private var testing = false
    @State private var heard = false
    @State private var phase: Double = 0
    @State private var peak: Float = 0
    @State private var localLevel: Float = 0
    @State private var levelTimer: Timer?
    @State private var inputDevices: [String] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("Say a few words to check your mic is working. The bars should rise with your voice.")
                .font(.system(size: 14))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)

            // Live waveform bar meter
            HStack(spacing: 3) {
                ForEach(0..<28, id: \.self) { i in
                    Capsule()
                        .fill(barColor(i))
                        .frame(width: 4, height: barHeight(i))
                }
            }
            .frame(height: 56)
            .frame(maxWidth: 320)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(Color.calmSurface(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: C.rMD, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: C.rMD, style: .continuous)
                    .stroke(Color.calmBorder, lineWidth: 1)
            )

            // Status line
            HStack(spacing: 6) {
                CalmStatusDot(status: heard ? .success : (testing ? .recording : .idle))
                Text(heard ? "Mic is working" : (testing ? "Listening…" : "Tap to start the test"))
                    .font(.system(size: 12))
                    .foregroundStyle(heard ? .calmSuccess : Color.calmLabel3(for: scheme))
            }

            // Device picker (diagnostic)
            if !inputDevices.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mic")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                    Text(inputDevices.first ?? "Default input")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
            }

            VStack(spacing: 8) {
                if heard {
                    Button("Continue") { stopTest(); onContinue() }
                        .buttonStyle(CalmButtonStyle(prominent: true, tint: Color.calmAccent(for: scheme), scheme: scheme))
                } else {
                    Button(testing ? "Stop" : "Start mic test") { testing ? stopTest() : startTest() }
                        .buttonStyle(CalmButtonStyle(prominent: true, tint: Color.calmAccent(for: scheme), scheme: scheme))
                }
                HStack(spacing: 14) {
                    Button("Open Sound Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmAccent(for: scheme))

                    Button("Skip") { stopTest(); onContinue() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
            }
        }
        .onAppear { loadDevices() }
        .onDisappear { stopTest() }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base: CGFloat = 4
        guard testing || heard else { return base }
        let lvl = CGFloat(max(localLevel, 0.02))
        // Symmetric envelope so the centre bars react most.
        let center = abs(CGFloat(i) - 13.5) / 13.5
        let envelope = 1 - center * 0.6
        let wobble = sin(phase * 1.3 + Double(i) * 0.55) * 0.4 + 0.6
        let h = base + lvl * 48 * envelope * CGFloat(wobble)
        return min(max(h, base), 52)
    }

    private func barColor(_ i: Int) -> Color {
        if heard { return .calmSuccess.opacity(0.85) }
        if testing { return Color.calmAccent(for: scheme).opacity(0.85) }
        return Color.calmLabel5(for: scheme)
    }

    private func startTest() {
        do {
            try AudioRecorder.shared.startRecording()
            testing = true
            peak = 0
            levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                phase += 0.18
                let lvl = AudioRecorder.shared.audioLevel
                localLevel = localLevel * 0.6 + lvl * 0.4
                peak = max(peak, lvl)
                if peak > 0.12 && !heard {
                    heard = true
                    if UserDefaults.standard.bool(forKey: "soundEnabled") {
                        SoundFeedback.shared.playSuccessTone()
                    }
                }
            }
        } catch {
            NSLog("[Haynoi] Mic test: start failed — %@", error.localizedDescription)
        }
    }

    private func stopTest() {
        levelTimer?.invalidate(); levelTimer = nil
        if AudioRecorder.shared.isRunning {
            _ = AudioRecorder.shared.stopRecording()
        }
        testing = false
        localLevel = 0
    }

    private func loadDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        inputDevices = session.devices.map { $0.localizedName }
    }
}

// MARK: - Hotkey Test (superwhisper-style key graphic that lights on press)

/// Shows the chosen hotkey as a key graphic that lights up while the modifier is
/// held. Uses a local NSEvent monitor (Input Monitoring is granted by now).
/// "Change shortcut" is inline (writes the same `hotkeyChoice` AppStorage key
/// SettingsView owns).

struct HotkeyTestView: View {
    let scheme: ColorScheme
    let onContinue: () -> Void

    @AppStorage("hotkeyChoice") private var hotkeyChoice = "command"
    @State private var pressed = false
    @State private var didPress = false
    @State private var monitor: Any?
    @State private var showChange = false

    private var symbol: String {
        switch hotkeyChoice {
        case "option":  return "⌥"
        case "control": return "⌃"
        case "fn":      return "fn"
        default:        return "⌘"
        }
    }

    private var name: String {
        switch hotkeyChoice {
        case "option":  return "Option"
        case "control": return "Control"
        case "fn":      return "Globe"
        default:        return "Command"
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Press and hold your push-to-talk key. It should light up below.")
                .font(.system(size: 14))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 340)

            // Key graphic
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(pressed ? Color.calmAccent(for: scheme) : Color.calmSurface(for: scheme))
                    .frame(width: 96, height: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(pressed ? Color.calmAccent(for: scheme) : Color.calmBorderMed,
                                    lineWidth: pressed ? 2 : 1)
                    )
                    .shadow(color: pressed ? Color.calmAccent(for: scheme).opacity(0.35) : .black.opacity(0.06),
                            radius: pressed ? 14 : 4, y: pressed ? 4 : 2)
                    .scaleEffect(pressed ? 0.96 : 1)

                VStack(spacing: 2) {
                    Text(symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(pressed ? .white : Color.calmLabel(for: scheme))
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(pressed ? .white.opacity(0.85) : Color.calmLabel4(for: scheme))
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)

            HStack(spacing: 6) {
                CalmStatusDot(status: didPress ? .success : .idle)
                Text(didPress ? "Hotkey detected" : "Waiting for key…")
                    .font(.system(size: 12))
                    .foregroundStyle(didPress ? .calmSuccess : Color.calmLabel3(for: scheme))
            }

            // Inline change-shortcut
            if showChange {
                Picker("", selection: $hotkeyChoice) {
                    Text("⌘ Command").tag("command")
                    Text("⌥ Option").tag("option")
                    Text("⌃ Control").tag("control")
                    Text("fn Globe").tag("fn")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                .onChange(of: hotkeyChoice) { _, newValue in
                    applyHotkeyChoice(newValue)
                }
            } else {
                Button("Change shortcut") { withAnimation { showChange = true } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmAccent(for: scheme))
            }

            VStack(spacing: 8) {
                Button("Continue") { onContinue() }
                    .buttonStyle(CalmButtonStyle(prominent: true, tint: Color.calmAccent(for: scheme), scheme: scheme))
                    .opacity(didPress ? 1 : 0.55)
                if !didPress {
                    Button("Skip") { onContinue() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
            }
        }
        .onAppear { startMonitor() }
        .onDisappear { stopMonitor() }
    }

    private var targetFlag: NSEvent.ModifierFlags {
        switch hotkeyChoice {
        case "option":  return .option
        case "control": return .control
        case "fn":      return .function
        default:        return .command
        }
    }

    private func startMonitor() {
        // Local monitor — fires while the onboarding window is key. Input
        // Monitoring (granted by now) lets us read modifier flags reliably.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            let down = event.modifierFlags.contains(targetFlag)
            DispatchQueue.main.async {
                withAnimation { pressed = down }
                if down && !didPress {
                    didPress = true
                    if UserDefaults.standard.bool(forKey: "soundEnabled") {
                        SoundFeedback.shared.playSuccessTone()
                    }
                }
            }
            return event
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func applyHotkeyChoice(_ choice: String) {
        switch choice {
        case "option":  HotkeyManager.shared.targetModifier = .maskAlternate
        case "control": HotkeyManager.shared.targetModifier = .maskControl
        case "fn":      HotkeyManager.shared.targetModifier = .maskSecondaryFn
        default:        HotkeyManager.shared.targetModifier = .maskCommand
        }
        // Reset detection so the user tests the newly chosen key.
        didPress = false
        pressed = false
        NSLog("[Haynoi] Hotkey test: choice changed to %@", choice)
    }
}

// MARK: - App Icon Drag Chip View
//
// A draggable chip that carries Bundle.main.bundleURL as its drag payload.
// System Settings panes accept this exactly like a Finder drop (F1.4).
// Re-dressed in the calm look; the NSDraggingSession mechanism is unchanged.

struct AppIconDragChipView: View {
    @Binding var chipState: DragChipState
    let scheme: ColorScheme
    let onDragEnd: () -> Void

    @State private var breathingScale: CGFloat = 1.0

    private var isDragging: Bool { chipState == .dragging }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Dashed drop-hint outline visible during drag (accent indigo).
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        Color.calmAccent(for: scheme).opacity(isDragging ? 0.6 : 0),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .frame(width: 68, height: 68)
                    .animation(.easeInOut(duration: 0.2), value: isDragging)

                // App icon: breathing at idle, lifts on drag. The aurora glow is
                // allowed here (icon is one of its sanctioned homes).
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.calmHairline(for: scheme), lineWidth: 1)
                    )
                    .shadow(
                        color: Color.calmAccent(for: scheme).opacity(isDragging ? 0.4 : 0.12),
                        radius: isDragging ? 14 : 5,
                        y: isDragging ? 7 : 2
                    )
                    .scaleEffect(isDragging ? 1.08 : breathingScale)
                    .overlay(
                        BundleDragSourceView(
                            onDragWillBegin: {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    chipState = .dragging
                                }
                            },
                            onDragEnded: {
                                if chipState == .dragging {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        chipState = .waiting
                                    }
                                }
                                onDragEnd()
                            }
                        )
                    )
            }

            Text("Drag me into the list")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.calmLabel3(for: scheme))
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathingScale = 1.04
            }
        }
    }
}

/// Transparent AppKit overlay that drags the app bundle exactly like Finder:
/// mouseDown + 3pt of travel begins an NSDraggingSession whose pasteboard
/// writer is the bundle's NSURL (public.file-url) — the payload the System
/// Settings permission lists validate. draggingSession(_:endedAt:) is the
/// authoritative end signal, so no safety timers are needed.
private struct BundleDragSourceView: NSViewRepresentable {
    var onDragWillBegin: () -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        view.onDragWillBegin = onDragWillBegin
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.onDragWillBegin = onDragWillBegin
        nsView.onDragEnded = onDragEnded
    }

    final class DragSourceNSView: NSView, NSDraggingSource {
        var onDragWillBegin: (() -> Void)?
        var onDragEnded: (() -> Void)?
        private var pressOrigin: NSPoint?

        override func mouseDown(with event: NSEvent) {
            pressOrigin = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = pressOrigin else { return }
            let loc = event.locationInWindow
            guard hypot(loc.x - origin.x, loc.y - origin.y) > 3 else { return }
            pressOrigin = nil

            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            let icon = NSApp.applicationIconImage ?? NSImage()
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            pressOrigin = nil
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            DispatchQueue.main.async { self.onDragWillBegin?() }
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                             operation: NSDragOperation) {
            DispatchQueue.main.async { self.onDragEnded?() }
        }
    }
}

// MARK: - Drag-Grant Sheet Host (Settings → Permissions Fix)
//
// Presented from Settings → Permissions tab when a permission is not yet granted.
// Mirrors the drag-grant onboarding step in a sheet (D8 / D26), re-dressed calm,
// and now carries the same AX-trust-stale Relaunch fallback.

struct DragGrantSheetHost: View {
    let permissionType: DragGrantPermissionType
    @Binding var isPresented: Bool

    @State private var granted = false
    @State private var chipState: DragChipState = .idle
    @State private var fallbackVisible = false
    @State private var fallbackTimer: Timer?
    @State private var settingsOpenTask: DispatchWorkItem?
    @State private var pollTimer: Timer?
    @State private var staleSince: Date?
    @State private var relaunchNudge = false

    @Environment(\.colorScheme) private var scheme

    private static let staleGrantThreshold: TimeInterval = 10

    var body: some View {
        VStack(spacing: 0) {
            CalmHairline()
            VStack(spacing: 18) {
                Text(permissionType.title)
                    .font(.calmTitle)
                    .foregroundStyle(Color.calmLabel(for: scheme))
                    .padding(.top, 24)

                if granted {
                    grantedView
                } else {
                    pendingView
                }

                Button("Done") { isPresented = false }
                    .buttonStyle(CalmButtonStyle(prominent: false, tint: Color.calmAccent(for: scheme), scheme: scheme))
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 28)
        }
        .frame(width: 420, height: 480)
        .background(Color.calmBackground(for: scheme))
        .onAppear { beginSheet() }
        .onDisappear {
            pollTimer?.invalidate()
            fallbackTimer?.invalidate()
            settingsOpenTask?.cancel()
        }
    }

    private var grantedView: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.calmSuccess.opacity(0.12)).frame(width: 64, height: 64)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.calmSuccess)
            }
            Label("Permission granted", systemImage: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.calmSuccess)
        }
        .transition(.opacity.combined(with: .scale))
    }

    private var pendingView: some View {
        VStack(spacing: 14) {
            Text(permissionType.body)
                .font(.system(size: 14))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 320)

            AppIconDragChipView(
                chipState: $chipState,
                scheme: scheme,
                onDragEnd: {
                    fallbackTimer?.invalidate()
                    fallbackTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { _ in
                        DispatchQueue.main.async {
                            withAnimation { fallbackVisible = true }
                        }
                    }
                }
            )

            if chipState == .waiting {
                Text("Now flip the switch next to Haynoi in the list.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel3(for: scheme))
                    .transition(.opacity)
            }

            if relaunchNudge {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.calmWarn)
                        Text("The toggle looks on, but Haynoi hasn't picked it up. A quick relaunch finishes the grant.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.calmLabel2(for: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Relaunch Haynoi") { relaunchApp() }
                        .buttonStyle(CalmButtonStyle(prominent: true, tint: .calmWarn, scheme: scheme))
                }
                .padding(11)
                .background(Color.calmWarnBg)
                .clipShape(RoundedRectangle(cornerRadius: C.rMD, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: C.rMD, style: .continuous)
                        .stroke(Color.calmWarn.opacity(0.25), lineWidth: 1)
                )
            }

            Button("Reopen System Settings") {
                guard let url = URL(string: permissionType.paneURL) else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Color.calmAccent(for: scheme))

            if fallbackVisible {
                fallbackBlock
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Button("Having trouble?") {
                    withAnimation { fallbackVisible = true }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.calmLabel4(for: scheme))
            }
        }
    }

    private var fallbackBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual instructions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.calmLabel3(for: scheme))
            Text(permissionType.fallbackInstructions)
                .font(.system(size: 11))
                .foregroundStyle(Color.calmLabel3(for: scheme))
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
        }
        .padding(11)
        .background(Color.calmSubtle(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: C.rMD, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: C.rMD, style: .continuous).stroke(Color.calmBorder, lineWidth: 1))
        .frame(maxWidth: 340)
    }

    private func relaunchApp() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("[Haynoi] DragGrantSheet relaunch failed — %@", error.localizedDescription)
        }
    }

    private func beginSheet() {
        let alreadyGranted: Bool
        switch permissionType {
        case .inputMonitoring: alreadyGranted = CGPreflightListenEventAccess()
        case .accessibility:   alreadyGranted = AXIsProcessTrusted()
        }

        if alreadyGranted {
            withAnimation { granted = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { isPresented = false }
            return
        }

        let task = DispatchWorkItem {
            guard let url = URL(string: permissionType.paneURL) else { return }
            NSWorkspace.shared.open(url)
            NSLog("[Haynoi] Settings Fix sheet: opened pane %@", permissionType.paneURL)
        }
        settingsOpenTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { _ in
            DispatchQueue.main.async { withAnimation { fallbackVisible = true } }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            DispatchQueue.main.async {
                let nowGranted: Bool
                switch permissionType {
                case .inputMonitoring: nowGranted = CGPreflightListenEventAccess()
                case .accessibility:   nowGranted = AXIsProcessTrusted()
                }

                // AX-trust-stale fallback: user acted (chip waiting) but the
                // process still reads not-granted after the threshold.
                if !nowGranted, chipState == .waiting {
                    if staleSince == nil { staleSince = Date() }
                    if let s = staleSince,
                       Date().timeIntervalSince(s) >= Self.staleGrantThreshold,
                       !relaunchNudge {
                        withAnimation { relaunchNudge = true }
                    }
                } else if nowGranted {
                    staleSince = nil
                }

                guard nowGranted, !granted else { return }
                if UserDefaults.standard.bool(forKey: "soundEnabled") {
                    SoundFeedback.shared.playSuccessTone()
                }
                if case .inputMonitoring = permissionType {
                    let armed = HotkeyManager.shared.start()
                    NSLog("[Haynoi] Settings Fix sheet: hotkey arm = %d", armed ? 1 : 0)
                }
                withAnimation { granted = true; relaunchNudge = false }
                pollTimer?.invalidate()
                fallbackTimer?.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { isPresented = false }
            }
        }
    }
}

// MARK: - DragGrantPermissionType (shared between onboarding and settings sheet)

enum DragGrantPermissionType {
    case inputMonitoring
    case accessibility

    var paneURL: String {
        switch self {
        case .inputMonitoring:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
    }

    var title: String {
        switch self {
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility:   return "Accessibility"
        }
    }

    var body: String {
        switch self {
        case .inputMonitoring:
            return "Drag the Haynoi icon into the Input Monitoring list — or if it is already listed, just flip the switch."
        case .accessibility:
            return "Drag the Haynoi icon into the Accessibility list — or if it is already listed, just flip the switch."
        }
    }

    var fallbackInstructions: String {
        switch self {
        case .inputMonitoring:
            return "Open System Settings → Privacy & Security → Input Monitoring. Click the + button, navigate to your Applications folder, and select Haynoi. Then enable it with the toggle."
        case .accessibility:
            return "Open System Settings → Privacy & Security → Accessibility. Click the + button, navigate to your Applications folder, and select Haynoi. Then enable it with the toggle."
        }
    }
}

// MARK: - Ambient onboarding music
//
// TODO (deferred this build): superwhisper plays a soft ambient pad during
// onboarding to set a calm tone. Skipped here to avoid blocking on audio
// assets. Wire a looping low-volume player gated behind `muteMusic` when an
// onboarding pad asset lands in Resources/Sounds.
