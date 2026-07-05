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

    // v1.1 — separate clickable window for the learn toast (the orb window is
    // ignoresMouseEvents = true, so it can't host buttons).
    private var toastWindow: NSWindow?
    private var toastDismissTimer: Timer?

    private init() {}

    // MARK: - Lifecycle

    /// Shows the orb in recording state.  No-op if already visible.
    @MainActor func show() {
        // The orb must read as "recording" the instant it appears so the user
        // sees it's listening — without this it renders the empty .idle state
        // until the first transition() and only becomes visible after speaking.
        AppState.shared.orbState = .recording

        guard window == nil else { return }

        let view = FloatingBarView()
            .environmentObject(AppState.shared)
        let hosting = NSHostingView(rootView: view)

        // Wide enough for the Trail waveform strip + the "N words" success chip.
        let size = NSSize(width: 180, height: 80)
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

    // MARK: - v1.1 Correction hint + Learn toast

    /// Brief visual cue that "fix that" armed correction mode. Lean: reuse the orb
    /// success-chip surface to flash a small "✏️ Sửa" chip. The substantive UI is
    /// the learn toast at the end of the correction.
    @MainActor func showCorrectionHint() {
        AppState.shared.lastDictationWordCount = 0  // force the generic chip path off
        show()
        transition(to: .success) // reuses the chip styling; auto-hides after dwell
    }

    /// Non-modal, auto-dismissing learn toast with two inline actions (§5). Lives
    /// in its own clickable window below the orb's top-center slot. 6s auto-dismiss
    /// is treated as "ignore" (no learn). Replaces any toast already on screen.
    @MainActor func showLearnToast(wrong: String, right: String,
                                   onRemember: @escaping () -> Void,
                                   onIgnore: @escaping () -> Void) {
        dismissLearnToast(fireIgnore: false) // clear any prior toast (no double-ignore)

        let view = LearnToastView(
            wrong: wrong,
            right: right,
            onRemember: { [weak self] in
                self?.toastDismissTimer?.invalidate(); self?.toastDismissTimer = nil
                onRemember()
                self?.tearDownToastWindow()
            },
            onIgnore: { [weak self] in
                self?.toastDismissTimer?.invalidate(); self?.toastDismissTimer = nil
                onIgnore()
                self?.tearDownToastWindow()
            }
        )
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 320, height: 64)
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
        win.ignoresMouseEvents = false // clickable — hosts the two buttons
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // A row under the orb slot so they don't overlap.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - size.width / 2
            let y = visible.maxY - 80 /* orb height */ - 10 - size.height - 8
            win.setFrameOrigin(NSPoint(x: x, y: y))
        }
        win.animationBehavior = .none
        win.orderFront(nil)
        toastWindow = win

        // 6s auto-dismiss = ignored.
        let timer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                onIgnore()
                self?.tearDownToastWindow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        toastDismissTimer = timer
    }

    /// Dismisses any visible learn toast. When `fireIgnore` is true the ignore
    /// path is NOT invoked here (callers that replace a toast pass false).
    @MainActor func dismissLearnToast(fireIgnore: Bool) {
        toastDismissTimer?.invalidate()
        toastDismissTimer = nil
        tearDownToastWindow()
    }

    @MainActor private func tearDownToastWindow() {
        guard let win = toastWindow else { return }
        win.orderOut(nil)
        let hosting = win.contentView
        toastWindow = nil
        DispatchQueue.main.async {
            win.contentView = nil
            _ = hosting
        }
    }

    // MARK: - Private

    private func repositionWindow(_ win: NSWindow, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Top-center, just below the menu bar (visibleFrame excludes it) —
        // founder feedback 2026-06-12: the indicator lives up top, not above
        // the Dock, so it never collides with what you're typing into.
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 10
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
    @State private var levelHistory: [CGFloat] = Array(repeating: 0, count: 6)
    /// Scrolling level history for the Trail waveform — newest sample last.
    @State private var trailHistory: [CGFloat] = Array(repeating: 0, count: 40)
    @State private var displayLink: Timer?

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
        .frame(width: 180, height: 80)
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

    // MARK: - Recording Orb — "Trail" (founder pick, 2026-06-12 contest)
    //
    // Voice-Memos style scrolling history: the newest level sample lands on
    // the right and older bars march left, dimming with age — the last second
    // of your voice stays visible. HONEST by construction: silence appends
    // zero-height samples, so a quiet trail is a flat line of dashes — there
    // is no time-driven motion of bar amplitude at all.

    private let trailBarCount = 40
    private let trailBarWidth: CGFloat = 2.6
    private let trailBarGap: CGFloat = 1.2
    private let trailMaxBarHeight: CGFloat = 30

    /// Shared "cosmic" capsule — fixed dark obsidian (always dark, floats over other apps).
    /// Border: hairline white at 10% opacity. Halo: single-hue Signal Cyan — swells with voice.
    private func cosmicCapsule(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [Color.orbBodyTop, Color.orbBodyBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.38), radius: 10, y: 3)
            // Single-hue Signal Cyan halo — swells with mic envelope, no aurora violet
            .shadow(color: Color.accent.opacity(min(0.06 + displayLevel * 1.4, 0.38)), radius: CGFloat(6) + displayLevel * 12)
    }

    private var recordingOrb: some View {
        ZStack {
            cosmicCapsule(width: 176, height: 52)

            Canvas { context, size in
                let stride = trailBarWidth + trailBarGap
                let total = CGFloat(trailHistory.count) * stride - trailBarGap
                let x0 = (size.width - total) / 2
                let midY = size.height / 2
                for (i, v) in trailHistory.enumerated() {
                    let h = max(1.8, min(v, 1) * trailMaxBarHeight)
                    let rect = CGRect(x: x0 + CGFloat(i) * stride,
                                      y: midY - h / 2,
                                      width: trailBarWidth,
                                      height: h)
                    let path = Path(roundedRect: rect, cornerRadius: trailBarWidth / 2)
                    let age = CGFloat(i) / CGFloat(max(trailHistory.count - 1, 1)) // 0 old → 1 new
                    if v < 0.05 {
                        // Quiet dash — 40% white on the dark obsidian pill, honest silence
                        context.fill(path, with: .color(Color.white.opacity(0.40 * age + 0.12)))
                    } else {
                        // Active bar — single-hue Signal Cyan, opacity fades with age
                        var bar = context
                        bar.opacity = 0.18 + 0.82 * age
                        bar.fill(path, with: .linearGradient(
                            Gradient(colors: [Color.accent, Color.accentDeep]),
                            startPoint: CGPoint(x: rect.midX, y: rect.maxY),
                            endPoint: CGPoint(x: rect.midX, y: rect.minY)
                        ))
                    }
                }
            }
            .frame(width: 156, height: 40)
            .shadow(color: Color.accent.opacity(0.28), radius: 4)
        }
        .frame(width: 180, height: 76)
    }

    // MARK: - Transcribing — intentionally invisible
    //
    // Founder feedback 2026-06-12: no violet dot while waiting. Release →
    // quiet — the next thing you see is the "N words" chip (or the error pill).

    private var transcribingOrb: some View {
        Color.clear
    }

    // MARK: - Success — "N words" chip (founder pick, 2026-06-12 contest)
    //
    // A small green capsule springs in with the word count of the dictation
    // that just landed — confirmation + a tiny reward in one beat. Falls back
    // to the plain check orb if the count is somehow unknown.

    private var successOrb: some View {
        Group {
            if state.lastDictationWordCount > 0 {
                HStack(spacing: 6) {
                    // Checkmark: Signal Cyan solid — single-hue, no aurora gradient
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accent)
                    // Word count: JetBrains Mono tabular, dark-surface body ink
                    Text(wordsLabel(state.lastDictationWordCount))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.inkDarkBody)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.orbBodyTop, Color.orbBodyBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        // Signal Cyan border on success chip (per mockup rgba(56,225,198,0.24))
                        .overlay(Capsule().stroke(Color.accent.opacity(0.24), lineWidth: 1))
                        .shadow(color: .black.opacity(0.38), radius: 10, y: 3)
                        // Single-hue cyan glow — no violet
                        .shadow(color: Color.accent.opacity(0.18), radius: 12)
                )
                .scaleEffect(successScale)
                .animation(.spring(response: 0.32, dampingFraction: 0.62), value: successScale)
            } else {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.orbBodyTop, Color.orbBodyBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(Circle().stroke(Color.accent.opacity(0.24), lineWidth: 1))
                        .frame(width: 26, height: 26)
                        .shadow(color: Color.accent.opacity(0.22), radius: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accent)
                        .scaleEffect(successScale)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: successScale)
                }
            }
        }
        .onAppear {
            successScale = 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                successScale = 1.0
            }
        }
    }

    private func wordsLabel(_ n: Int) -> String {
        n == 1 ? "1 word" : "\(n) words"
    }

    // MARK: - Error Orb (obsidian elevated body, dark hairline border, amber glyph)

    private var errorOrb: some View {
        ZStack {
            Circle()
                // Elevated dark obsidian (#131416) — not full-depth gradient
                .fill(Color.obsidianDarkElevated)
                .overlay(Circle().stroke(Color.hairlineDarkSolid, lineWidth: 1))
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)

            Image(systemName: "exclamationmark")
                .font(.system(size: 14, weight: .bold))
                // Semantic amber #D9A441 per spec (obsidianDarkWarn)
                .foregroundStyle(Color.obsidianDarkWarn)
        }
    }

    // MARK: - State Transitions

    private func handleStateChange(_ newState: OrbState) {
        switch newState {
        case .recording:
            orbVisible = true
            // Fresh dictation — the trail starts flat.
            trailHistory = Array(repeating: 0, count: trailBarCount)

        case .transcribing:
            // Intentionally invisible (renders Color.clear) — the window stays
            // alive so the "N words" chip can spring in on success.
            orbVisible = true

        case .success:
            orbVisible = true
            // Dwell long enough to read the "N words" chip. Bail if a new
            // dictation already moved the orb on — never tear down its window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
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
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor [self] in
                guard state.orbState == .recording else { return }

                // Raw mic level with a tiny floor so the orb never reads as 0
                // (silence still shows a low, *still* bar — not a flat line).
                let rawLevel = CGFloat(max(state.audioLevel, 0.0))
                levelHistory.append(rawLevel)
                if levelHistory.count > 6 { levelHistory.removeFirst() }

                // Short weighted-average so the input isn't jittery, but stays
                // responsive — recent frames dominate.
                let weights: [CGFloat] = [0.05, 0.08, 0.12, 0.15, 0.25, 0.35]
                var smoothed: CGFloat = 0
                for (i, w) in weights.enumerated() {
                    if i < levelHistory.count { smoothed += levelHistory[i] * w }
                }

                // Calm resting floor — silence parks at ~0.04 (≈5pt bars).
                let target = max(smoothed, 0.04)
                // Fast attack (~50ms to ~63%), slower graceful release (~200ms)
                // so speech onset is instant and decay glides down, never bobs.
                let attack: CGFloat = 0.33   // up
                let release: CGFloat = 0.085 // down
                let speed = target > displayLevel ? attack : release
                displayLevel += (target - displayLevel) * speed

                // Trail: newest sample lands on the right; silence appends ~0,
                // which renders as a flat dash — no synthetic motion ever.
                trailHistory.append(smoothed)
                if trailHistory.count > trailBarCount {
                    trailHistory.removeFirst(trailHistory.count - trailBarCount)
                }
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

// MARK: - Learn Toast (v1.1 — "Nhớ: <wrong> → <right>?")

/// Non-modal learn prompt shown after an explicit "fix that" correction. Two
/// inline actions: Nhớ (remember → upsert learned replacement) / Bỏ qua (ignore).
struct LearnToastView: View {
    let wrong: String
    let right: String
    let onRemember: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nhớ?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.inkDarkBody.opacity(0.7))
                HStack(spacing: 4) {
                    Text(wrong)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.inkDarkBody.opacity(0.8))
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accent)
                    Text(right)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accent)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(action: onRemember) {
                Text("Nhớ")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accent.opacity(0.16)))
            }
            .buttonStyle(.plain)
            Button(action: onIgnore) {
                Text("Bỏ qua")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.inkDarkBody.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.orbBodyTop, Color.orbBodyBottom],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.38), radius: 12, y: 4)
        )
        .frame(width: 320, height: 64)
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
