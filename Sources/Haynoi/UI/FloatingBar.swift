import SwiftUI
import AppKit

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

/// Option A caption pill — frosted glass, fixed width, top-center under the
/// menu bar. Never becomes key (PTT must not steal scroll).
class FloatingBarController {
    static let shared = FloatingBarController()

    private var window: OverlayPanel?
    private var hostingView: NSView?

    // v1.1 — separate clickable window for the learn toast (the orb window is
    // ignoresMouseEvents = true, so it can't host buttons).
    private var toastWindow: OverlayPanel?
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

        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1440
        let size = CaptionLayout.pillSize(screenWidth: screenWidth)
        hosting.frame = NSRect(origin: .zero, size: size)

        let win = OverlayPanel.makeIndicator(size: size, clickThrough: true)
        win.contentView = hosting
        applyFrame(win, hosting: hosting, size: size)
        win.presentWithoutActivating()
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

    #if DEBUG
    /// Writes the live orb view to PNG (own-window snapshot — no Screen Recording TCC).
    @MainActor func debugSnapshot(to url: URL) {
        guard let view = hostingView else {
            NSLog("[Haynoi] debugSnapshot: no hosting view")
            return
        }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        NSLog("[Haynoi] debugSnapshot wrote %@", url.path)
    }

    @MainActor var debugWindowFrame: NSRect? { window?.frame }

    @MainActor var debugWindowNumber: Int { window?.windowNumber ?? 0 }
    #endif

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
        AppState.shared.interimPartial = ""
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
    /// in its own clickable window one row above the caption pill. 6s auto-dismiss
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

        let win = OverlayPanel.makeIndicator(size: size, clickThrough: false)
        win.contentView = hosting
        if let screen = NSScreen.main {
            win.setFrame(OverlayPanel.toastFrame(size: size, visibleFrame: screen.visibleFrame), display: true)
        }
        win.presentWithoutActivating()
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

    private func applyFrame(_ win: NSWindow, hosting: NSView, size: NSSize) {
        hosting.frame = NSRect(origin: .zero, size: size)
        guard let screen = NSScreen.main else {
            win.setContentSize(size)
            return
        }
        win.setFrame(
            OverlayPanel.topCenteredFrame(size: size, visibleFrame: screen.visibleFrame),
            display: true
        )
    }
}

// MARK: - The Visual

/// The floating orb view.  Reads `AppState.orbState` to switch between
/// recording, transcribing, success, and error visuals.
struct FloatingBarView: View {
    @EnvironmentObject private var state: AppState

    @State private var successScale: CGFloat = 1.0
    @State private var orbVisible: Bool = true
    /// Grow-only committed prefix so Vietnamese tokens already shown stay put.
    @State private var lockedCommitted: String = ""
    @State private var listenPulse = false

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(orbVisible ? 1 : 0)
        .scaleEffect(orbVisible ? 1 : 0.7)
        .animation(.easeInOut(duration: 0.2), value: orbVisible)
        .onChange(of: state.orbState) { _, newState in
            handleStateChange(newState)
        }
        .onChange(of: state.interimPartial) { _, new in
            let advanced = CaptionLayout.advanceLock(raw: new, locked: lockedCommitted)
            lockedCommitted = advanced.newLock
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            orbVisible = true
            listenPulse = true
        }
    }

    // MARK: - Option A — frosted pill, text only, invisible when silent

    @ViewBuilder
    private var recordingOrb: some View {
        if interimLine.isEmpty, state.orbState == .recording {
            listenDot
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if interimLine.isEmpty {
            Color.clear
        } else {
            HStack(spacing: 8) {
                if state.orbState == .recording {
                    listenDot
                }
                marqueeCaption
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HUDBlur().clipShape(Capsule()))
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
        }
    }

    private var listenDot: some View {
        Circle()
            .fill(Color.white.opacity(listenPulse ? 0.22 : 0.75))
            .frame(width: 4, height: 4)
            .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: listenPulse)
            .accessibilityLabel("Listening")
    }

    private var marqueeCaption: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Text(captionAttributed)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id("caption-end")
                }
            }
            .scrollDisabled(true)
            .onAppear {
                proxy.scrollTo("caption-end", anchor: .trailing)
            }
            .onChange(of: interimLine) { _, _ in
                proxy.scrollTo("caption-end", anchor: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
    }

    private var captionAttributed: AttributedString {
        // After release the clause is committed — drop bold so it reads as settled.
        if state.orbState != .recording {
            var settled = AttributedString(interimLine)
            settled.font = .system(size: CaptionLayout.fontSize, weight: .light)
            settled.foregroundColor = Color.white.opacity(0.78)
            return settled
        }
        let parts = CaptionLayout.advanceLock(raw: state.interimPartial, locked: lockedCommitted)
        var result = AttributedString()
        if !parts.committed.isEmpty {
            var committed = AttributedString(parts.committed)
            committed.font = .system(size: CaptionLayout.fontSize, weight: .light)
            committed.foregroundColor = Color.white.opacity(0.78)
            result += committed
            if !parts.fresh.isEmpty {
                result += AttributedString(" ")
            }
        }
        if !parts.fresh.isEmpty {
            var fresh = AttributedString(parts.fresh)
            fresh.font = .system(size: CaptionLayout.fontSize, weight: .semibold)
            fresh.foregroundColor = Color.white.opacity(0.96)
            result += fresh
        }
        return result
    }

    private var interimLine: String {
        state.interimPartial.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transcribing
    //
    // Hold ended: keep the last on-device line, all regular (no bold tail),
    // until the "N words" chip or error pill replaces it.

    @ViewBuilder
    private var transcribingOrb: some View {
        if interimLine.isEmpty {
            Color.clear
        } else {
            recordingOrb
        }
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
            lockedCommitted = ""

        case .transcribing:
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

}

/// Frosted glass behind the Option A pill — blurs whatever is under the HUD.
private struct HUDBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
