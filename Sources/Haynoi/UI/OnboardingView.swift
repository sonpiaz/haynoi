import SwiftUI
import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers

// MARK: - Onboarding Step Enum

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case microphone
    case inputMonitoring
    case accessibility
    case signIn
    case tryIt

    var totalCount: Int { OnboardingStep.allCases.count }

    // Steps that show the progress indicator (everything after Welcome)
    var showsProgress: Bool { self != .welcome }

    // Zero-based index among the progress steps
    var progressIndex: Int { rawValue - 1 }

    // Whether this step uses drag-grant choreography
    var isDragStep: Bool { self == .inputMonitoring || self == .accessibility }
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

    // Window choreography state
    @State private var windowChoreographyActive = false

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

    // MARK: - Stateless resume (D2)
    //
    // On every launch with onboarding incomplete, jump to the first unsatisfied step
    // computed from live system state — no stored step index.

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
        VStack(spacing: 0) {
            // Aurora hairline — aligns with the main window
            AuroraHairline()

            appHeader

            progressDots
                .opacity(step.showsProgress ? 1 : 0)
                .animation(.easeInOut(duration: 0.3), value: step.showsProgress)

            ZStack {
                switch step {
                case .welcome:         welcomeStep
                case .microphone:      microphoneStep
                case .inputMonitoring: inputMonitoringStep
                case .accessibility:   accessibilityStep
                case .signIn:          signInStep
                case .tryIt:           tryItStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step.rawValue)
            .animation(.easeInOut(duration: 0.3), value: step.rawValue)

            Spacer()
        }
        .frame(width: 460, height: 580)
        .background(Color.mercuryBackground(for: scheme))
        .onAppear {
            refreshPermissions()
            startPolling()
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
        }
    }

    // MARK: - Header

    private var appHeader: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
                .padding(.top, 28)

            Text(headerTitle)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(Color.mercuryLabel2(for: scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.bottom, 16)
    }

    private var headerTitle: String {
        switch step {
        case .welcome:         return "Welcome to Haynoi"
        case .microphone:      return "Allow Microphone Access"
        case .inputMonitoring: return "Allow Input Monitoring"
        case .accessibility:   return "Allow Accessibility"
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
        guard step.showsProgress else { return Color.mercuryMid(for: scheme) }
        if i < step.progressIndex { return Color.mercuryGreen }
        if i == step.progressIndex { return Color.auroraViolet }
        return Color.mercuryMid(for: scheme)
    }

    // MARK: - Step Bodies

    // Step A: Welcome
    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Text("Haynoi lets you dictate into any app by holding \(HotkeyDisplay.symbol). Set up takes about a minute.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button("Get Started") { advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(width: 160)
                .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }

    // Step B: Microphone — standard system prompt (unchanged per SPEC F1.8)
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

    // Step C: Input Monitoring — drag-grant choreography (F1.1-F1.7, D1-D5)
    private var inputMonitoringStep: some View {
        dragGrantStep(
            paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            granted: inputGranted,
            chipState: $imChipState,
            fallbackVisible: $imFallbackVisible,
            onDragEnd: { resetFallbackTimer(for: .inputMonitoring) },
            body: "Drag the Haynoi icon into the Input Monitoring list — or if it is already listed, just flip the switch.",
            fallbackInstructions: "Open System Settings → Privacy & Security → Input Monitoring. Click the + button, navigate to your Applications folder, and select Haynoi. Then enable it with the toggle.",
            reopenAction: { reopenPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") },
            showRelaunchNudge: hotkeyArmFailed
        )
    }

    // Step D: Accessibility — drag-grant choreography (F1.1-F1.7, D1-D5)
    private var accessibilityStep: some View {
        dragGrantStep(
            paneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            granted: axGranted,
            chipState: $axChipState,
            fallbackVisible: $axFallbackVisible,
            onDragEnd: { resetFallbackTimer(for: .accessibility) },
            body: "Drag the Haynoi icon into the Accessibility list — or if it is already listed, just flip the switch.",
            fallbackInstructions: "Open System Settings → Privacy & Security → Accessibility. Click the + button, navigate to your Applications folder, and select Haynoi. Then enable it with the toggle.",
            reopenAction: { reopenPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") },
            showRelaunchNudge: false
        )
    }

    // Step E: Sign In
    private var signInStep: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(signInCircleColor)
                    .frame(width: 64, height: 64)
                Image(systemName: signInCircleIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(signInIconColor)
            }
            .animation(.easeInOut(duration: 0.2), value: authState.signedInEmail != nil)

            Text("Connect your Kyma account — free credit included. Dictation needs an account to transcribe.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if let email = authState.signedInEmail {
                VStack(spacing: 10) {
                    Label(email, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Button("Continue") { advance() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(width: 160)
                }
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Button(isSigningIn ? "Opening browser…" : "Sign in with Kyma") { signIn() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(isSigningIn)
                        if isSigningIn { ProgressView().controlSize(.small) }
                    }
                    if !signInError.isEmpty {
                        Text(signInError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                    Button("Skip for now") { advance() }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private var signInCircleColor: Color {
        authState.signedInEmail != nil ? .green.opacity(0.12) : .blue.opacity(0.1)
    }
    private var signInCircleIcon: String {
        authState.signedInEmail != nil ? "checkmark.circle.fill" : "person.crop.circle.fill"
    }
    private var signInIconColor: Color {
        authState.signedInEmail != nil ? .green : .blue
    }

    // Step F: Try It
    private var tryItStep: some View {
        VStack(spacing: 16) {
            if trialCelebrating {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 64, height: 64)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                        .scaleEffect(trialCelebrating ? 1.1 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: trialCelebrating)
                }
            }

            Text("Hold **\(HotkeyDisplay.symbol)** and say what you're thinking. Release to transcribe.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            TextEditor(text: $trialText)
                .font(.body)
                .frame(height: 80)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                .padding(.horizontal, 2)

            VStack(spacing: 8) {
                Button("Finish") {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(width: 160)

                Button("Skip") {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    onComplete()
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 32)
        .onAppear { baselineTranscriptionCount = AppState.shared.transcriptions.count }
    }

    // MARK: - Drag-Grant Step Layout

    @ViewBuilder
    private func dragGrantStep(
        paneURL: String,
        granted: Bool,
        chipState: Binding<DragChipState>,
        fallbackVisible: Binding<Bool>,
        onDragEnd: @escaping () -> Void,
        body: String,
        fallbackInstructions: String,
        reopenAction: @escaping () -> Void,
        showRelaunchNudge: Bool
    ) -> some View {
        // Translocation guard: compiled out in DEBUG builds (D7)
        #if !DEBUG
        if isTranslocated {
            translocationCard.padding(.horizontal, 32)
        } else {
            dragGrantContent(
                granted: granted,
                chipState: chipState,
                fallbackVisible: fallbackVisible,
                onDragEnd: onDragEnd,
                body: body,
                fallbackInstructions: fallbackInstructions,
                reopenAction: reopenAction,
                showRelaunchNudge: showRelaunchNudge
            )
        }
        #else
        dragGrantContent(
            granted: granted,
            chipState: chipState,
            fallbackVisible: fallbackVisible,
            onDragEnd: onDragEnd,
            body: body,
            fallbackInstructions: fallbackInstructions,
            reopenAction: reopenAction,
            showRelaunchNudge: showRelaunchNudge
        )
        #endif
    }

    @ViewBuilder
    private func dragGrantContent(
        granted: Bool,
        chipState: Binding<DragChipState>,
        fallbackVisible: Binding<Bool>,
        onDragEnd: @escaping () -> Void,
        body: String,
        fallbackInstructions: String,
        reopenAction: @escaping () -> Void,
        showRelaunchNudge: Bool
    ) -> some View {
        VStack(spacing: 18) {
            if granted {
                // Granted state: check mark animation; no tone here — tone fires in poll (D5)
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 64, height: 64)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.mercuryGreen)
                    }
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.mercuryGreen)
                    Button("Continue") { advance() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(width: 160)
                }
                .animation(.easeInOut(duration: 0.25), value: granted)
            } else {
                // Pending: chip + fallback
                VStack(spacing: 14) {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)

                    // Draggable app icon chip (F1.3-F1.4)
                    AppIconDragChipView(
                        chipState: chipState,
                        scheme: scheme,
                        onDragEnd: onDragEnd
                    )
                    .accessibilityLabel("Haynoi icon — drag into the System Settings list")
                    .accessibilityAction(named: "Show manual instructions") {
                        // VoiceOver action reveals fallback instructions (F1.8)
                        withAnimation { fallbackVisible.wrappedValue = true }
                    }

                    // "Flip the switch" hint appears after a drag session ends (waiting state)
                    if chipState.wrappedValue == .waiting {
                        Text("Now flip the switch next to Haynoi in the list.")
                            .font(.caption)
                            .foregroundStyle(Color.mercuryLabel3(for: scheme))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: chipState.wrappedValue)
                    }

                    // Relaunch nudge: surfaces only at Input Monitoring if arm failed
                    if showRelaunchNudge {
                        VStack(spacing: 6) {
                            Text("Haynoi needs to relaunch to activate the hotkey after granting.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 300)
                            Button("Relaunch Haynoi") { relaunchApp() }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .controlSize(.regular)
                        }
                        .padding(.top, 4)
                    }

                    // Reopen Settings link (always present — D25)
                    Button("Reopen System Settings") { reopenAction() }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(Color.auroraBlue)

                    // 25s fallback (D4): revealed below the chip, chip stays usable
                    if fallbackVisible.wrappedValue {
                        fallbackBlock(instructions: fallbackInstructions)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        Button("Having trouble?") {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                fallbackVisible.wrappedValue = true
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func fallbackBlock(instructions: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual instructions")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color.mercuryLabel3(for: scheme))
            Text(instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .background(Color.mercuryWarm(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mercuryDivider(for: scheme), lineWidth: 1))
        .frame(maxWidth: 340)
    }

    // MARK: - Translocation Card (D7 — release builds only)

    private var translocationCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.mercuryAccentLight)
                    .frame(width: 64, height: 64)
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.mercuryAccent)
            }
            Text("Move Haynoi to your Applications folder before granting permissions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Text("macOS is running Haynoi from a temporary location. Drag it to Applications and relaunch — permissions will then stick properly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 10) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Button("Relaunch after moving") { relaunchApp() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
    }

    // MARK: - Shared Permission Step Layout (Microphone only)

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
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.12) : Color.blue.opacity(0.1))
                    .frame(width: 64, height: 64)
                Image(systemName: granted ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 28))
                    .foregroundStyle(granted ? .green : .blue)
            }
            .animation(.easeInOut(duration: 0.25), value: granted)

            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if granted {
                VStack(spacing: 10) {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Button("Continue") { advance() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(width: 160)
                }
            } else if isDenied {
                VStack(spacing: 10) {
                    Button("Open System Settings") {
                        if let url = URL(string: deniedURL) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(width: 180)
                    troubleDisclosure(hint: troubleHint)
                }
            } else {
                VStack(spacing: 10) {
                    Button("Grant Access") { grantAction() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(width: 160)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 4)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
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

        // Raise window level so our window stays visible above Settings (D9)
        raiseWindowLevel()
        // Reposition for side-by-side when screen is wide enough (D9: >= 1280pt)
        repositionWindowForDragStep()
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

    private func repositionWindowForDragStep() {
        guard let screen = NSScreen.main,
              let window = findOnboardingWindow() else { return }
        let screenWidth = screen.visibleFrame.width
        // Side-by-side only when screen is wide enough (D9: >= 1280pt threshold)
        guard screenWidth >= 1280 else { return }
        let margin: CGFloat = 24
        let x = screen.visibleFrame.minX + margin
        let y = screen.visibleFrame.midY - window.frame.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
        NSLog("[Haynoi] Onboarding: repositioned side-by-side (screen %.0fpt wide)", screenWidth)
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
        // On drag-session end, reset the 25s timer (D4)
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

    // MARK: - Translocation Detection (D7)

    private var isTranslocated: Bool {
        !Bundle.main.bundleURL.path.hasPrefix("/Applications")
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

                // Detect not-granted → granted transition for tone (D5)
                let inputJustGranted = !wasInputGranted && inputGranted
                let axJustGranted = !wasAxGranted && axGranted

                // Auto-advance when the current permission step is satisfied
                if step == .microphone && micGranted {
                    withAnimation { advance() }
                } else if step == .inputMonitoring && inputGranted {
                    // Play success tone on the transition (D5; no tone when already granted)
                    if inputJustGranted && UserDefaults.standard.bool(forKey: "soundEnabled") {
                        SoundFeedback.shared.playSuccessTone()
                    }
                    withAnimation { imChipState = .granted }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation { advance() }
                    }
                } else if step == .accessibility && axGranted {
                    if axJustGranted && UserDefaults.standard.bool(forKey: "soundEnabled") {
                        SoundFeedback.shared.playSuccessTone()
                    }
                    withAnimation { axChipState = .granted }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation { advance() }
                    }
                }

                // Try to arm hotkey once Input Monitoring flips to granted (preserved behavior)
                if inputJustGranted {
                    let armed = HotkeyManager.shared.start()
                    NSLog("[Haynoi] Onboarding: hotkey arm after grant = %d", armed ? 1 : 0)
                    if !armed { hotkeyArmFailed = true }
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - App Icon Drag Chip View
//
// A draggable chip that carries Bundle.main.bundleURL as its drag payload.
// System Settings panes accept this exactly like a Finder drop (F1.4).
// Styled with a subtle breathing animation at idle and a lift on drag.

struct AppIconDragChipView: View {
    @Binding var chipState: DragChipState
    let scheme: ColorScheme
    let onDragEnd: () -> Void

    @State private var breathingScale: CGFloat = 1.0

    private var isDragging: Bool { chipState == .dragging }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Dashed drop-hint outline visible during drag
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        Color.auroraViolet.opacity(isDragging ? 0.6 : 0),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .frame(width: 76, height: 76)
                    .animation(.easeInOut(duration: 0.2), value: isDragging)

                // App icon: breathing at idle, lifts on drag
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(
                        color: Color.auroraViolet.opacity(isDragging ? 0.45 : 0.15),
                        radius: isDragging ? 16 : 6,
                        y: isDragging ? 8 : 3
                    )
                    .scaleEffect(isDragging ? 1.08 : breathingScale)
                    .overlay(
                        // Finder-grade drag: SwiftUI's onDrag wraps the bundle in a
                        // data representation System Settings rejects; a real
                        // NSDraggingSession with an NSURL pasteboard writer is
                        // accepted like a drag from Finder, starts on first
                        // press-move, and reports its end authoritatively.
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
                .foregroundStyle(Color.mercuryLabel3(for: scheme))
        }
        .onAppear {
            // Subtle breathing animation (F1.5 idle state)
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

// MARK: - Drag-Grant Sheet Host
//
// Presented from Settings → Permissions tab when a permission is not yet granted.
// Mirrors the drag-grant onboarding step in a sheet (D8 / D26).

struct DragGrantSheetHost: View {
    let permissionType: DragGrantPermissionType
    @Binding var isPresented: Bool

    @State private var granted = false
    @State private var chipState: DragChipState = .idle
    @State private var fallbackVisible = false
    @State private var fallbackTimer: Timer?
    @State private var settingsOpenTask: DispatchWorkItem?
    @State private var pollTimer: Timer?

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            AuroraHairline()
            VStack(spacing: 20) {
                Text(permissionType.title)
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.mercuryLabel2(for: scheme))
                    .padding(.top, 24)

                if granted {
                    grantedView
                } else {
                    pendingView
                }

                Button("Done") { isPresented = false }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 28)
        }
        .frame(width: 400, height: 420)
        .background(Color.mercuryBackground(for: scheme))
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
                Circle().fill(Color.green.opacity(0.12)).frame(width: 64, height: 64)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.mercuryGreen)
            }
            Label("Permission granted", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Color.mercuryGreen)
        }
        .transition(.opacity.combined(with: .scale))
    }

    private var pendingView: some View {
        VStack(spacing: 14) {
            Text(permissionType.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            AppIconDragChipView(
                chipState: $chipState,
                scheme: scheme,
                onDragEnd: {
                    // Reset 25s fallback timer on drag-session end (D4)
                    fallbackTimer?.invalidate()
                    fallbackTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { _ in
                        DispatchQueue.main.async {
                            withAnimation { fallbackVisible = true }
                        }
                    }
                }
            )
            .frame(width: 200, height: 90)

            Button("Reopen System Settings") {
                guard let url = URL(string: permissionType.paneURL) else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(Color.auroraBlue)

            if fallbackVisible {
                fallbackBlock
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Button("Having trouble?") {
                    withAnimation { fallbackVisible = true }
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var fallbackBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Manual instructions")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Color.mercuryLabel3(for: scheme))
            Text(permissionType.fallbackInstructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .background(Color.mercuryWarm(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mercuryDivider(for: scheme), lineWidth: 1))
        .frame(maxWidth: 340)
    }

    private func beginSheet() {
        let alreadyGranted: Bool
        switch permissionType {
        case .inputMonitoring: alreadyGranted = CGPreflightListenEventAccess()
        case .accessibility:   alreadyGranted = AXIsProcessTrusted()
        }

        // D26: if already granted at presentation, show check and auto-dismiss ~800ms
        if alreadyGranted {
            withAnimation { granted = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { isPresented = false }
            return
        }

        // Auto-open pane ~600ms after sheet renders (D1)
        let task = DispatchWorkItem {
            guard let url = URL(string: permissionType.paneURL) else { return }
            NSWorkspace.shared.open(url)
            NSLog("[Haynoi] Settings Fix sheet: opened pane %@", permissionType.paneURL)
        }
        settingsOpenTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)

        // 25s fallback
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: false) { _ in
            DispatchQueue.main.async { withAnimation { fallbackVisible = true } }
        }

        // Poll for grant (1.5s cadence matching onboarding poll)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            DispatchQueue.main.async {
                let nowGranted: Bool
                switch permissionType {
                case .inputMonitoring: nowGranted = CGPreflightListenEventAccess()
                case .accessibility:   nowGranted = AXIsProcessTrusted()
                }
                guard nowGranted, !granted else { return }
                // Play success tone on transition (D5)
                if UserDefaults.standard.bool(forKey: "soundEnabled") {
                    SoundFeedback.shared.playSuccessTone()
                }
                // Re-arm hotkey if Input Monitoring was just granted
                if case .inputMonitoring = permissionType {
                    let armed = HotkeyManager.shared.start()
                    NSLog("[Haynoi] Settings Fix sheet: hotkey arm = %d", armed ? 1 : 0)
                }
                withAnimation { granted = true }
                pollTimer?.invalidate()
                fallbackTimer?.invalidate()
                // Auto-dismiss ~800ms after grant is shown (D8)
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
