import SwiftUI
import AppKit
import Combine

// MARK: - Orb State

/// Drives the visual state machine of the floating orb.
/// PipelineController is the only writer; FloatingBarView observes AppState.
enum OrbState: Equatable {
    case recording          // mic is hot — animated ember + waveform ring
    case transcribing       // mic released, waiting for STT response
    case success            // text inserted — brief tick then fade-out
    case error              // something went wrong — brief flash then fade-out
    case idle               // window hidden (intermediate before orderOut)
}

// MARK: - Controller

/// Floating voice indicator — pure visual, no text, never blocks clicks.
/// Positioning: bottom-center of the main display, above the Dock.
class FloatingBarController {
    static let shared = FloatingBarController()

    private var window: NSWindow?
    private var hostingView: NSView?

    private init() {}

    // MARK: - Lifecycle

    /// Shows the orb in recording state.  No-op if already visible.
    @MainActor func show() {
        guard window == nil else { return }

        let view = FloatingBarView()
            .environmentObject(AppState.shared)
        let hosting = NSHostingView(rootView: view)

        let size = NSSize(width: 80, height: 80)
        hosting.frame = NSRect(origin: .zero, size: size)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = hosting
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .floating
        win.hasShadow = false
        // Pure indicator — must never intercept mouse events from the target app
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        repositionWindow(win, size: size)

        win.animationBehavior = .none
        win.orderFront(nil)
        window = win
        hostingView = hosting
    }

    /// Transitions to a non-recording state (transcribing / success / error).
    /// Callers should follow up with hide() after the appropriate dwell time
    /// for success/error states.  No-op if the window is not visible.
    @MainActor func transition(to newState: OrbState) {
        guard window != nil else { return }
        AppState.shared.orbState = newState
    }

    /// Hides and destroys the orb window.
    @MainActor func hide() {
        guard let win = window else { return }
        win.orderOut(nil)

        let hosting = hostingView
        window = nil
        hostingView = nil
        DispatchQueue.main.async {
            win.contentView = nil
            _ = hosting
        }
        // Reset orb state so next show() starts fresh
        AppState.shared.orbState = .idle
    }

    // MARK: - Private

    private func repositionWindow(_ win: NSWindow, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Bottom-center, 24pt above the bottom edge of the visible frame
        // (sits neatly above the Dock on default-position configs).
        let x = visible.midX - size.width / 2
        let y = visible.minY + 24
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - The Visual

/// The floating orb view.  Reads `AppState.orbState` to switch between
/// recording, transcribing, success, and error visuals.
struct FloatingBarView: View {
    @EnvironmentObject private var state: AppState

    // Audio-reactive fields — updated by the display link when recording
    @State private var displayLevel: CGFloat = 0.05
    @State private var phase: Double = 0
    @State private var breathe: Double = 0
    @State private var levelHistory: [CGFloat] = Array(repeating: 0.05, count: 6)
    @State private var displayLink: Timer?

    // Transcribing pulse
    @State private var transcribePulse: Double = 0

    // Success / error — checkmark scale + color injection
    @State private var successScale: CGFloat = 1.0
    @State private var successOpacity: Double = 1.0
    @State private var orbVisible: Bool = true

    var body: some View {
        ZStack {
            switch state.orbState {
            case .recording:
                recordingOrb
            case .transcribing:
                transcribingOrb
            case .success:
                successOrb
            case .error:
                errorOrb
            case .idle:
                // Should not be visible in idle; hide is driven externally.
                Color.clear
            }
        }
        .frame(width: 80, height: 80)
        .opacity(orbVisible ? 1 : 0)
        .scaleEffect(orbVisible ? 1 : 0.7)
        .animation(.easeInOut(duration: 0.2), value: orbVisible)
        .onChange(of: state.orbState) { _, newState in
            handleStateChange(newState)
        }
        .onAppear {
            startAnimationLoop()
            orbVisible = true
        }
        .onDisappear {
            stopAnimationLoop()
        }
    }

    // MARK: - Recording Orb (aurora palette)

    private var recordingOrb: some View {
        ZStack {
            // Outer glow — aurora-tinted, breathes with voice
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.3, green: 0.85, blue: 0.95).opacity(0.22 * displayLevel + 0.06),
                            Color(red: 0.45, green: 0.25, blue: 0.85).opacity(0.12 * displayLevel),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 38
                    )
                )
                .frame(width: 72, height: 72)
                .scaleEffect(1.0 + displayLevel * 0.45 + breathe * 0.06)
                .blur(radius: 2)

            // Aurora ring — the aura
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.3, green: 0.9, blue: 0.95).opacity(0.25 + displayLevel * 0.35),
                            Color(red: 0.7, green: 0.35, blue: 0.95).opacity(0.2 + displayLevel * 0.25),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 38 + displayLevel * 8, height: 38 + displayLevel * 8)
                .blur(radius: 1)

            // Waveform ring — voice visualizer, aurora-colored
            WaveformRing(level: displayLevel, phase: phase)
                .fill(
                    AngularGradient(
                        colors: [
                            Color(red: 0.25, green: 0.85, blue: 0.95).opacity(0.9),
                            Color(red: 0.55, green: 0.3, blue: 0.9).opacity(0.7),
                            Color(red: 0.85, green: 0.35, blue: 0.75).opacity(0.85),
                            Color(red: 0.35, green: 0.7, blue: 0.95).opacity(0.75),
                            Color(red: 0.25, green: 0.85, blue: 0.95).opacity(0.9),
                        ],
                        center: .center
                    )
                )
                .frame(width: 42, height: 42)

            // Core — aurora gem
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.55, green: 0.9, blue: 1.0),         // bright icy center
                            Color(red: 0.4, green: 0.5, blue: 0.95),          // deep blue-violet mid
                            Color(red: 0.3, green: 0.15, blue: 0.65),         // deep violet edge
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 9
                    )
                )
                .frame(width: 16, height: 16)
                .shadow(color: Color(red: 0.3, green: 0.8, blue: 1.0).opacity(0.8),
                        radius: 4 + displayLevel * 6)
                .shadow(color: Color(red: 0.6, green: 0.3, blue: 0.95).opacity(0.4),
                        radius: 10 + displayLevel * 8)
                .scaleEffect(1.0 + displayLevel * 0.2)
        }
    }

    // MARK: - Transcribing Orb (calm indigo, pulsing — matches status-dot language)

    private var transcribingOrb: some View {
        ZStack {
            // Indigo outer glow — reads as "thinking", same hue as the menubar dot
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.calmAccent.opacity(0.18 + transcribePulse * 0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 32
                    )
                )
                .frame(width: 64, height: 64)
                .scaleEffect(0.88 + transcribePulse * 0.06)
                .blur(radius: 2)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                           value: transcribePulse)

            // Thin indigo ring
            Circle()
                .stroke(
                    Color.calmAccent.opacity(0.40 + transcribePulse * 0.18),
                    lineWidth: 1.5
                )
                .frame(width: 34, height: 34)
                .blur(radius: 0.5)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                           value: transcribePulse)

            // Core — calm indigo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.calmAccent.opacity(0.9),
                            Color.calmAccentHover,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 8
                    )
                )
                .frame(width: 13, height: 13)
                .scaleEffect(0.92 + transcribePulse * 0.08)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                           value: transcribePulse)
        }
        .onAppear { transcribePulse = 1.0 }
    }

    // MARK: - Success Orb (calm success green)

    private var successOrb: some View {
        ZStack {
            // Green glow burst
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.calmSuccess.opacity(0.32),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 36
                    )
                )
                .frame(width: 68, height: 68)
                .blur(radius: 2)

            // Core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.calmSuccess.opacity(0.95),
                            Color.calmSuccess,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 9
                    )
                )
                .frame(width: 22, height: 22)
                .shadow(color: Color.calmSuccess.opacity(0.6), radius: 8)

            // Checkmark
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .scaleEffect(successScale)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: successScale)
        }
        .onAppear {
            successScale = 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                successScale = 1.0
            }
        }
    }

    // MARK: - Error Orb (calm warn amber)

    private var errorOrb: some View {
        ZStack {
            // Warm glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.calmWarn.opacity(0.35),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 36
                    )
                )
                .frame(width: 68, height: 68)
                .blur(radius: 2)

            // Core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.calmWarn.opacity(0.95),
                            Color.calmWarn,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 9
                    )
                )
                .frame(width: 22, height: 22)
                .shadow(color: Color.calmWarn.opacity(0.6), radius: 8)

            // Exclamation
            Image(systemName: "exclamationmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - State Transitions

    private func handleStateChange(_ newState: OrbState) {
        switch newState {
        case .recording:
            orbVisible = true
            transcribePulse = 0

        case .transcribing:
            orbVisible = true
            // transcribing pulse handled in the view's onAppear

        case .success:
            orbVisible = true
            // Fade out after a brief dwell. Bail if a new dictation already
            // moved the orb to another state — never tear down its window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard state.orbState == .success else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    orbVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard state.orbState == .success else { return }
                    FloatingBarController.shared.hide()
                }
            }

        case .error:
            orbVisible = true
            // Stay visible for 1.5s then fade — same stale-closure guard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard state.orbState == .error else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    orbVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard state.orbState == .error else { return }
                    FloatingBarController.shared.hide()
                }
            }

        case .idle:
            break
        }
    }

    // MARK: - Animation Loop (recording only)

    private func startAnimationLoop() {
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
            breathe = 1.0
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor [self] in
                guard state.orbState == .recording else { return }

                let rawLevel = CGFloat(max(state.audioLevel, 0.03))
                levelHistory.append(rawLevel)
                if levelHistory.count > 6 { levelHistory.removeFirst() }

                let weights: [CGFloat] = [0.05, 0.08, 0.12, 0.15, 0.25, 0.35]
                var smoothed: CGFloat = 0
                for (i, w) in weights.enumerated() {
                    if i < levelHistory.count { smoothed += levelHistory[i] * w }
                }

                let target = max(smoothed, 0.05)
                let speed: CGFloat = target > displayLevel ? 0.35 : 0.12
                displayLevel += (target - displayLevel) * speed

                phase += 0.04 + Double(displayLevel) * 0.08
            }
        }
        // commonModes so updates survive modal runs
        RunLoop.main.add(timer, forMode: .common)
        displayLink = timer
    }

    private func stopAnimationLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

// MARK: - Waveform Ring Shape (shared with status bar)

struct WaveformRing: Shape {
    var level: CGFloat
    var phase: Double

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(level, phase) }
        set { level = newValue.first; phase = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius: CGFloat = min(rect.width, rect.height) / 2 - 3
        let barCount = 32
        let barWidth: CGFloat = 2.0

        for i in 0..<barCount {
            let angle = (Double(i) / Double(barCount)) * 2.0 * .pi - .pi / 2

            let freq1 = sin(phase * 1.0 + Double(i) * 0.6) * 0.5 + 0.5
            let freq2 = cos(phase * 0.6 + Double(i) * 0.4) * 0.3 + 0.5
            let freq3 = sin(phase * 1.4 + Double(i) * 0.9) * 0.2 + 0.5
            let response = freq1 * 0.45 + freq2 * 0.35 + freq3 * 0.20

            let maxExtension: CGFloat = 12
            let extension_ = maxExtension * level * CGFloat(response)
            let minBar: CGFloat = 2.0

            let innerR = baseRadius - minBar
            let outerR = baseRadius + max(extension_, 0.5)

            let cosA = CGFloat(cos(angle))
            let sinA = CGFloat(sin(angle))

            let inner = CGPoint(x: center.x + innerR * cosA, y: center.y + innerR * sinA)
            let outer = CGPoint(x: center.x + outerR * cosA, y: center.y + outerR * sinA)

            let perpX = -sinA * barWidth / 2
            let perpY = cosA * barWidth / 2

            path.move(to: CGPoint(x: inner.x + perpX, y: inner.y + perpY))
            path.addLine(to: CGPoint(x: outer.x + perpX, y: outer.y + perpY))
            path.addLine(to: CGPoint(x: outer.x - perpX, y: outer.y - perpY))
            path.addLine(to: CGPoint(x: inner.x - perpX, y: inner.y - perpY))
            path.closeSubpath()
        }

        return path
    }
}
