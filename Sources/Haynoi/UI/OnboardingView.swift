import SwiftUI
import AVFoundation
import ApplicationServices

// MARK: - Onboarding Step Enum

private enum OnboardingStep: Int, CaseIterable {
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
}

// MARK: - OnboardingView

struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
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
    @State private var trialTranscriptionCount = 0
    @State private var trialCelebrating = false

    var onComplete: () -> Void

    // Tracks how many transcriptions existed before Try It step began
    @State private var baselineTranscriptionCount = 0

    // Number of progress dots (steps after Welcome)
    private let progressStepCount = OnboardingStep.allCases.count - 1

    @Environment(\.colorScheme) private var scheme

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
                case .welcome:        welcomeStep
                case .microphone:     microphoneStep
                case .inputMonitoring: inputMonitoringStep
                case .accessibility:  accessibilityStep
                case .signIn:         signInStep
                case .tryIt:          tryItStep
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
        .frame(width: 460, height: 520)
        .background(Color.mercuryBackground(for: scheme))
        .onAppear {
            refreshPermissions()
            startPolling()
        }
        .onDisappear { stopPolling() }
        .onReceive(NotificationCenter.default.publisher(for: .haynoiDictationCompleted)) { _ in
            if step == .tryIt {
                handleTrialTranscription()
            }
        }
    }

    // MARK: - Header (Mercury paper/ink + serif title)

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
        case .welcome:        return "Welcome to Haynoi"
        case .microphone:     return "Allow Microphone Access"
        case .inputMonitoring: return "Allow Input Monitoring"
        case .accessibility:  return "Allow Accessibility"
        case .signIn:         return "Connect Your Account"
        case .tryIt:          return "Try Your First Dictation"
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

            Button("Get Started") {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(width: 160)
            .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }

    // Step B: Microphone
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

    // Step C: Input Monitoring
    private var inputMonitoringStep: some View {
        permissionStepView(
            icon: "keyboard.fill",
            granted: inputGranted,
            body: "Haynoi needs Input Monitoring to detect when you hold the \(HotkeyDisplay.symbol) key.",
            troubleHint: "Open System Settings → Privacy & Security → Input Monitoring, then toggle Haynoi on.",
            deniedURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            grantAction: {
                // Register in the system list and open preferences
                CGRequestListenEventAccess()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    // Step D: Accessibility
    private var accessibilityStep: some View {
        permissionStepView(
            icon: "hand.raised.fill",
            granted: axGranted,
            body: "Haynoi needs Accessibility to type text directly into any app you're using.",
            troubleHint: "Open System Settings → Privacy & Security → Accessibility, then toggle Haynoi on.",
            deniedURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            grantAction: {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
            }
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
                        Button(isSigningIn ? "Opening browser…" : "Sign in with Kyma") {
                            signIn()
                        }
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
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 0.5)
                )
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
        .onAppear {
            baselineTranscriptionCount = AppState.shared.transcriptions.count
        }
    }

    // MARK: - Shared Permission Step Layout

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

            // Relaunch nudge: surfaces only at Input Monitoring if arm failed
            if icon == "keyboard.fill" && hotkeyArmFailed && !granted {
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
            // Past final step — complete
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            onComplete()
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            step = next
        }
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
                // Auto-advance after successful sign-in
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
        // Pull the latest text into the trial text field
        if let latest = AppState.shared.transcriptions.first {
            trialText = latest.text
        }
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
        axGranted = AXIsProcessTrusted()
        inputGranted = CGPreflightListenEventAccess()
    }

    /// Returns true when a permission has been explicitly denied (not undetermined).
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
                refreshPermissions()
                // Auto-advance when the current permission step is granted
                let currentlyOnPermissionStep = (step == .microphone && micGranted)
                    || (step == .inputMonitoring && inputGranted)
                    || (step == .accessibility && axGranted)
                if currentlyOnPermissionStep {
                    withAnimation { advance() }
                }
                // Try to arm hotkey once Input Monitoring flips to granted
                if !wasInputGranted && inputGranted {
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
