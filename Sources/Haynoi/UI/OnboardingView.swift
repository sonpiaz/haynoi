import SwiftUI
import AVFoundation
import ApplicationServices

struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var micGranted = false
    @State private var axGranted = false
    @State private var inputGranted = false
    @State private var pollTimer: Timer?
    var onComplete: () -> Void

    private let steps: [(title: String, subtitle: String, icon: String)] = [
        ("Microphone", "Haynoi needs your mic to hear your voice and convert speech to text.", "mic.fill"),
        ("Accessibility", "Haynoi needs Accessibility to type text directly into any app you're using.", "hand.raised.fill"),
        ("Input Monitoring", "Haynoi needs Input Monitoring to detect when you hold the ⌘ key.", "keyboard.fill"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header with logo
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                Text("Welcome to Haynoi")
                    .font(.system(size: 24, weight: .bold))

                Text("Let's set up a few things so Haynoi can work its magic.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.bottom, 28)

            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(stepColor(i))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 24)

            // Step content
            if currentStep < 3 {
                permissionStep(index: currentStep)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(currentStep)
            } else {
                completionStep
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Spacer()
        }
        .frame(width: 440, height: 480)
        .background(.background)
        .animation(.easeInOut(duration: 0.3), value: currentStep)
        .onAppear {
            refreshPermissions()
            startPolling()
            skipGrantedSteps()
        }
        .onDisappear { stopPolling() }
    }

    // MARK: - Permission Step

    private func permissionStep(index: Int) -> some View {
        let step = steps[index]
        let granted = isGranted(index)

        return VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.12) : Color.blue.opacity(0.1))
                    .frame(width: 64, height: 64)
                Image(systemName: granted ? "checkmark.circle.fill" : step.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(granted ? .green : .blue)
            }

            VStack(spacing: 8) {
                Text("Step \(index + 1): \(step.title)")
                    .font(.headline)
                Text(step.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            } else {
                Button(action: { grantPermission(index) }) {
                    Text("Grant Access")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 160, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)

                if index > 0 {
                    Text("Haynoi will detect automatically when you grant it")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Completion

    private var completionStep: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
            }

            Text("You're all set!")
                .font(.title2.weight(.bold))

            Text("Hold **⌘ Command** and speak.\nRelease to transcribe.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: {
                UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                onComplete()
            }) {
                Text("Get Started")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 160, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    // MARK: - Helpers

    private func stepColor(_ i: Int) -> Color {
        if isGranted(i) { return .green }
        if i == currentStep { return .blue }
        return .gray.opacity(0.3)
    }

    private func isGranted(_ index: Int) -> Bool {
        switch index {
        case 0: return micGranted
        case 1: return axGranted
        case 2: return inputGranted
        default: return false
        }
    }

    private func grantPermission(_ index: Int) {
        switch index {
        case 0:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { refreshPermissions() }
            }
        case 1:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        case 2:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        inputGranted = CGPreflightListenEventAccess()
    }

    private func skipGrantedSteps() {
        // Advance past already-granted permissions
        while currentStep < 3 && isGranted(currentStep) {
            currentStep += 1
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshPermissions()
                // Auto-advance when current step gets granted
                if currentStep < 3 && isGranted(currentStep) {
                    withAnimation {
                        currentStep += 1
                    }
                    // Keep advancing past any already-granted steps
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        skipGrantedSteps()
                    }
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
