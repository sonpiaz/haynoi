import SwiftUI
import AppKit
import Combine

/// Floating voice indicator — pure visual, no text.
/// Design philosophy: a living, breathing ember of sound.
class FloatingBarController {
    static let shared = FloatingBarController()

    private var window: NSWindow?
    private var hostingView: NSView?

    private init() {}

    func show() {
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
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]
        win.ignoresMouseEvents = false

        // Position: top-center, tucked under menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.maxY - 16
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }

        win.animationBehavior = .none
        win.orderFront(nil)
        window = win
        hostingView = hosting
    }

    func hide() {
        guard let win = window else { return }
        win.orderOut(nil)

        let hosting = hostingView
        window = nil
        hostingView = nil
        DispatchQueue.main.async {
            win.contentView = nil
            _ = hosting
        }
    }
}

// MARK: - The Visual — A Living Sound Orb

struct FloatingBarView: View {
    @EnvironmentObject private var state: AppState

    // Smoothed audio level with momentum — organic, not jumpy
    @State private var displayLevel: CGFloat = 0.05
    @State private var phase: Double = 0
    @State private var breathe: Double = 0
    @State private var displayLink: Timer?
    @State private var levelHistory: [CGFloat] = Array(repeating: 0.05, count: 6)

    var body: some View {
        ZStack {
            // Layer 1: Outer glow pulse — breathes with voice
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.red.opacity(0.25 * displayLevel + 0.08),
                            Color(red: 1.0, green: 0.2, blue: 0.1).opacity(0.1 * displayLevel),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: 38
                    )
                )
                .frame(width: 72, height: 72)
                .scaleEffect(1.0 + displayLevel * 0.5 + breathe * 0.06)
                .blur(radius: 2)

            // Layer 2: Mid glow ring — the "aura"
            Circle()
                .stroke(
                    Color.red.opacity(0.2 + displayLevel * 0.3),
                    lineWidth: 1.5
                )
                .frame(width: 38 + displayLevel * 8, height: 38 + displayLevel * 8)
                .blur(radius: 1)

            // Layer 3: Waveform ring — the voice visualizer
            WaveformRing(
                level: displayLevel,
                phase: phase
            )
            .fill(
                AngularGradient(
                    colors: [
                        Color(red: 1.0, green: 0.3, blue: 0.2).opacity(0.9),
                        Color(red: 0.9, green: 0.15, blue: 0.1).opacity(0.5),
                        Color(red: 1.0, green: 0.4, blue: 0.3).opacity(0.8),
                        Color(red: 0.85, green: 0.1, blue: 0.1).opacity(0.6),
                        Color(red: 1.0, green: 0.3, blue: 0.2).opacity(0.9),
                    ],
                    center: .center
                )
            )
            .frame(width: 42, height: 42)

            // Layer 4: Core — the red ember heart
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.35, blue: 0.25),   // warm bright center
                            Color(red: 0.95, green: 0.2, blue: 0.15),   // mid
                            Color(red: 0.75, green: 0.08, blue: 0.1),   // deep crimson edge
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 9
                    )
                )
                .frame(width: 16, height: 16)
                .shadow(color: Color.red.opacity(0.7), radius: 4 + displayLevel * 6)
                .shadow(color: Color(red: 1.0, green: 0.3, blue: 0.2).opacity(0.4), radius: 10 + displayLevel * 8)
                .scaleEffect(1.0 + displayLevel * 0.2)
        }
        .frame(width: 80, height: 80)
        .onAppear { startAnimationLoop() }
        .onDisappear { stopAnimationLoop() }
    }

    // MARK: - 60fps Animation Loop

    private func startAnimationLoop() {
        // Breathing
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
            breathe = 1.0
        }

        // Main display link — 60fps smooth updates
        displayLink = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            // Read raw level from audio engine
            let rawLevel = CGFloat(max(state.audioLevel, 0.03))

            // Push into history for smoothing
            levelHistory.append(rawLevel)
            if levelHistory.count > 6 { levelHistory.removeFirst() }

            // Weighted moving average — recent values matter more
            let weights: [CGFloat] = [0.05, 0.08, 0.12, 0.15, 0.25, 0.35]
            var smoothed: CGFloat = 0
            for (i, w) in weights.enumerated() {
                if i < levelHistory.count {
                    smoothed += levelHistory[i] * w
                }
            }

            // Ease toward target — fast attack, slow release (natural feel)
            let target = max(smoothed, 0.05)
            let speed: CGFloat = target > displayLevel ? 0.35 : 0.12
            displayLevel += (target - displayLevel) * speed

            // Phase rotation — speed varies with level
            phase += 0.04 + Double(displayLevel) * 0.08
        }
    }

    private func stopAnimationLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

// MARK: - Waveform Ring — Organic Voice Visualizer

struct WaveformRing: Shape {
    var level: CGFloat
    var phase: Double

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(level, phase) }
        set {
            level = newValue.first
            phase = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius: CGFloat = min(rect.width, rect.height) / 2 - 3
        let barCount = 32
        let barWidth: CGFloat = 2.0

        for i in 0..<barCount {
            let angle = (Double(i) / Double(barCount)) * 2.0 * .pi - .pi / 2

            // Multi-frequency response per bar — organic, never uniform
            let freq1 = sin(phase * 1.0 + Double(i) * 0.6) * 0.5 + 0.5
            let freq2 = cos(phase * 0.6 + Double(i) * 0.4) * 0.3 + 0.5
            let freq3 = sin(phase * 1.4 + Double(i) * 0.9) * 0.2 + 0.5
            let response = freq1 * 0.45 + freq2 * 0.35 + freq3 * 0.20

            // Bar extension — proportional to level × response
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
