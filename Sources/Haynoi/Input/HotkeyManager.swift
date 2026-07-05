import Carbon
import Cocoa

/// Detects modifier-only hold (default: ⌘ Command) via NSEvent global + local
/// monitors.
///
/// Key insight from Wispr Flow: when modifier is held past the grace period,
/// ALWAYS activate — even if other keys were pressed during the grace period.
/// The user pressed Cmd+T (shortcut) then kept holding Cmd to dictate.
/// Both the shortcut AND dictation should work.
///
/// Mechanism (engine change): we no longer use a CGEventTap (which required the
/// Input Monitoring TCC grant + a relaunch after granting). Instead we use:
///   • a GLOBAL monitor (NSEvent.addGlobalMonitorForEvents) — fires for events
///     in OTHER apps. This is the primary path: the user dictates while focused
///     in another app.
///   • a LOCAL monitor (NSEvent.addLocalMonitorForEvents) returning the event
///     unchanged — so the modifier is also detected when Haynoi itself is
///     frontmost.
/// Both monitors are passive observers; they never consume or modify events, so
/// shortcuts (Cmd+T etc.) pass through normally and the user gets both the
/// shortcut AND dictation.
///
/// Permission: NSEvent global keyboard monitors require the app to be trusted
/// for Accessibility (AXIsProcessTrusted()). Haynoi already requests
/// Accessibility for typing transcribed text, so this removes the separate
/// Input Monitoring permission entirely. The retry loop (every 2.5s + re-arm on
/// NSApplication.didBecomeActiveNotification) arms the monitors once
/// Accessibility is granted — no relaunch needed.
///
/// Fix #1: start() returns Bool and tracks `isActive` state. When Accessibility
/// is not yet granted, a retry loop fires every 2.5s and also re-arms on
/// NSApplication.didBecomeActiveNotification so grant-then-switch-back works
/// without a manual relaunch.
///
/// Fix #5: On NSApplication.didBecomeActiveNotification we resync isModifierDown
/// against the real hardware key state (NSEvent.modifierFlags). If the target
/// modifier is no longer physically down, we run the release path to end any
/// stuck recording (e.g. a release event missed while another app was frontmost
/// and the global monitor was throttled). We also check secure event input (via
/// the public Carbon API IsSecureEventInputEnabled()) so preRecording can reject
/// silently.

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onModifierDown: (() -> Void)?
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onCancelled: (() -> Void)?

    // MARK: - v1.1 "fix that" gesture (Signal C)
    //
    // A discrete TAP — semantically distinct from the push-to-talk hold machine —
    // that arms correction mode for the next dictation. It must never start/stop a
    // recording, so it is detected entirely in `handleFixThat`, isolated from
    // `isModifierDown` / `isActivated`.
    //
    // Conflict-free by construction: the recommended default is a ⌃⌥ CHORD tap.
    // Push-to-talk requires the SOLO target modifier held past the grace period
    // (`!hasOtherModifiers`, L376); the existing state machine CANCELS the moment a
    // second modifier is added — so a chord can never arm dictation. The
    // double-tap-Option alternative is for users whose push-to-talk is Control.
    var onFixThat: (() -> Void)?

    /// "ctrlOption" (⌃⌥ chord tap, default) | "doubleOption" (⌥⌥) | "off".
    /// Settable from Settings; reuses the two existing observe-only NSEvent
    /// monitors — no third monitor.
    var fixThatChoice: String = UserDefaults.standard.string(forKey: "fixThatHotkeyChoice") ?? "ctrlOption"

    // Fix-that chord (⌃⌥) tap tracking: a tap = both modifiers go down together
    // then fully release, with no intervening keyDown, inside a short window.
    private var fixChordArmed = false
    private var fixChordArmedAt: Date?
    private var sawKeyDownSinceChord = false
    // Double-tap-Option tracking.
    private var lastOptionTapAt: Date?
    private let fixTapWindow: TimeInterval = 0.6

    /// Public API kept as CGEventFlags so SettingsView's hotkey picker keeps
    /// working unchanged. Internally we translate to NSEvent.ModifierFlags.
    /// Default is Option (⌥) — the founder-approved push-to-talk key. When the
    /// target is Option we additionally require the LEFT option key (keyCode 58),
    /// so the right option key stays free for typing accented characters.
    var targetModifier: CGEventFlags = .maskAlternate

    /// Grace period — if modifier held longer than this, activate.
    /// 100ms: short enough to feel instant (founder feedback 2026-06-12 —
    /// "phải ngay vào luôn"), long enough to still swallow fast ⌥-chords.
    private let activationDelay: TimeInterval = 0.10

    // NSEvent monitor handles (global = other apps, local = Haynoi frontmost)
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var secureInputTimer: Timer?

    // Fix #1: retry state when permission not yet granted
    private var retryTimer: Timer?
    private var appBecameActiveObserver: NSObjectProtocol?

    // Fix #5: resync stuck modifier state when the app regains focus while the
    // monitors are already live (separate from the permission-poll observer).
    private var resyncObserver: NSObjectProtocol?

    private var isModifierDown = false
    private var isActivated = false
    private var activationWorkItem: DispatchWorkItem?

    /// keyCode of the most recent flagsChanged event. Used to distinguish the
    /// LEFT Option key (kVK_Option = 58) from the right one (kVK_RightOption = 61)
    /// when the target modifier is Option — only the left key triggers dictation.
    private var lastFlagKeyCode: UInt16 = 0

    // Carbon virtual key codes for the left/right option keys.
    private let kLeftOptionKeyCode: UInt16 = 58   // kVK_Option
    private let kRightOptionKeyCode: UInt16 = 61  // kVK_RightOption

    // Exposed state for AppState / onboarding
    private(set) var isActive = false

    private init() {}

    // MARK: - Modifier mapping (CGEventFlags → NSEvent.ModifierFlags)

    /// Translate the public CGEventFlags target into the NSEvent.ModifierFlags
    /// that the NSEvent monitors report. Keeps SettingsView's picker
    /// (.maskCommand / .maskAlternate / .maskControl / .maskSecondaryFn)
    /// working without any caller changes.
    private var targetFlag: NSEvent.ModifierFlags {
        switch targetModifier {
        case .maskAlternate:    return .option
        case .maskControl:      return .control
        case .maskSecondaryFn:  return .function
        default:                return .command
        }
    }

    // MARK: - Setup

    /// Starts the NSEvent monitors. Returns true if the monitors are now live.
    /// If Accessibility is not yet granted, schedules a retry loop so the
    /// monitors arm automatically once the user grants the permission and
    /// returns to Haynoi — no relaunch needed.
    @discardableResult
    func start() -> Bool {
        stop()

        // GATE on Accessibility, not Input Monitoring. NSEvent global keyboard
        // monitors only deliver events when the process is trusted for
        // Accessibility.
        guard AXIsProcessTrusted() else {
            NSLog("[Haynoi] Accessibility permission not granted — scheduling retry")
            scheduleRetry()
            isActive = false
            DispatchQueue.main.async { AppState.shared.hotkeyActive = false }
            return false
        }

        // GLOBAL monitor: fires for events in OTHER apps (primary path).
        // Does not return the event — global monitors are observe-only.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handle(event)
        }

        // LOCAL monitor: fires when Haynoi itself is frontmost. Must return the
        // event unchanged so it still reaches Haynoi's own UI.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }

        guard globalMonitor != nil else {
            NSLog("[Haynoi] Failed to install NSEvent global monitor")
            isActive = false
            DispatchQueue.main.async { AppState.shared.hotkeyActive = false }
            scheduleRetry()
            return false
        }

        NSLog("[Haynoi] NSEvent monitors started (modifier 0x%llx, delay %.0fms)",
              targetModifier.rawValue, activationDelay * 1000)

        isActive = true
        DispatchQueue.main.async { AppState.shared.hotkeyActive = true }

        // Cancel any pending retry — monitors are live
        cancelRetry()

        // Fix #5: resync the modifier state whenever the app regains focus, so a
        // release event missed while another app was frontmost can't leave a
        // stuck recording.
        if resyncObserver == nil {
            resyncObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resyncModifierState()
            }
        }

        // Watchdog: poll secure event input. When a password field or
        // screensaver is active, key events are routed away — starting a
        // recording would capture silence. The CGEventTap tap-disabled watchdog
        // no longer applies to NSEvent monitors, but the secure-input check
        // remains meaningful.
        DispatchQueue.main.async {
            self.secureInputTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                // IsSecureEventInputEnabled() is a public Carbon API
                // (available since macOS 10.4). The Timer runs on the main
                // RunLoop. Wrapped in Task @MainActor to satisfy the Swift
                // concurrency checker when reading AppState.
                let secureInput = Bool(IsSecureEventInputEnabled())
                Task { @MainActor in
                    if secureInput != AppState.shared.secureInputActive {
                        if secureInput {
                            NSLog("[Haynoi] Secure event input is active — recordings will be blocked")
                            // NSEvent monitors silently stop delivering during
                            // secure input (the old tap got an explicit disable
                            // event); a release may be missed, so resync now to
                            // clear any stuck modifier state.
                            self.resyncModifierState()
                        }
                        AppState.shared.secureInputActive = secureInput
                    }
                }
            }
        }
        return true
    }

    func stop() {
        secureInputTimer?.invalidate()
        secureInputTimer = nil
        cancelRetry()
        if let obs = resyncObserver {
            NotificationCenter.default.removeObserver(obs)
            resyncObserver = nil
        }
        activationWorkItem?.cancel()
        activationWorkItem = nil
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        isModifierDown = false
        isActivated = false
        isActive = false
    }

    // MARK: - Retry (Fix #1)

    private func scheduleRetry() {
        cancelRetry()

        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            NSLog("[Haynoi] Retrying HotkeyManager.start() (permission poll)")
            let ok = self.start()
            if ok { NSLog("[Haynoi] NSEvent monitors armed on retry (no relaunch needed)") }
        }

        // Also retry whenever the app comes back to the foreground — the user
        // may have just granted Accessibility and switched back
        if appBecameActiveObserver == nil {
            appBecameActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isActive else { return }
                NSLog("[Haynoi] App became active — retrying NSEvent monitors")
                self.start()
            }
        }
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let obs = appBecameActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            appBecameActiveObserver = nil
        }
    }

    // MARK: - App-active resync (Fix #5)

    /// Wired from AppState/AppDelegate on NSApplication.didBecomeActiveNotification.
    /// Reads the ACTUAL hardware modifier state (NSEvent.modifierFlags) and
    /// reconciles with our internal isModifierDown flag. If we think the
    /// modifier is held but it isn't (e.g. a release event was missed while
    /// another app was frontmost), synthetically fire the release path to clear
    /// stuck recording state.
    func resyncModifierState() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isModifierDown else { return }
        let actuallyDown = NSEvent.modifierFlags.contains(targetFlag)
        if !actuallyDown {
            NSLog("[Haynoi] Resync: modifier no longer held — firing synthetic release")
            isModifierDown = false
            activationWorkItem?.cancel()
            activationWorkItem = nil
            if isActivated {
                isActivated = false
                DispatchQueue.main.async { self.onKeyUp?() }
            } else {
                DispatchQueue.main.async { self.onCancelled?() }
            }
        }
    }

    // MARK: - Event Handling

    /// Routes an NSEvent from either monitor onto the main queue. flagsChanged
    /// drives the modifier state machine; keyDown during the grace window marks
    /// that another key was pressed (kept for diagnostics — shortcuts still
    /// activate dictation when the modifier is held past the grace period).
    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags
            let keyCode = event.keyCode
            DispatchQueue.main.async { self.handleFlagsChanged(flags, keyCode: keyCode) }
        case .keyDown:
            // Just for diagnostics — verify the monitor is alive. The old
            // onKeyDown semantics ("other key pressed") no longer gate
            // activation: holding the modifier past the grace period always
            // activates, exactly as the CGEventTap path behaved.
            // v1.1: a keyDown while the fix-that chord is held means it was used
            // as a real shortcut (e.g. ⌃⌥→ Mission Control) — not a tap.
            DispatchQueue.main.async { self.sawKeyDownSinceChord = true }
        default:
            break
        }
    }

    private func handleFlagsChanged(_ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) {
        dispatchPrecondition(condition: .onQueue(.main))
        // v1.1: additively detect the "fix that" tap. Isolated from the
        // push-to-talk state machine below — it never touches isModifierDown /
        // isActivated, so it can never start or stop a recording.
        handleFixThat(flags, keyCode: keyCode)

        lastFlagKeyCode = keyCode
        let isDown = flags.contains(targetFlag)

        // Left-option gate: when the target modifier is Option, only the LEFT
        // option key (keyCode 58) triggers dictation. The right option key (61)
        // is left free for typing accented characters. The release of a modifier
        // reports keyCode 0 in some paths, so we only gate the press; the press
        // is what arms the grace timer.
        if targetModifier == .maskAlternate && isDown && !isModifierDown {
            if keyCode == kRightOptionKeyCode {
                // Right option pressed — ignore entirely.
                return
            }
            // keyCode 58 (left) or 0 (ambiguous) → allow.
        }

        // Check no other modifiers are pressed (device-independent mask, minus
        // the target flag).
        let allModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let otherModifiers = flags.intersection(allModifiers).subtracting(targetFlag)
        let hasOtherModifiers = !otherModifiers.isEmpty

        if isDown && !isModifierDown && !hasOtherModifiers {
            // Modifier pressed
            isModifierDown = true
            activationWorkItem?.cancel()

            // Start mic immediately
            DispatchQueue.main.async { self.onModifierDown?() }

            // After grace period: if modifier STILL held → activate
            // Don't care about keyDown events — shortcuts pass through normally
            // with the observe-only monitors, user gets both shortcut AND
            // dictation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isModifierDown else { return }
                self.isActivated = true
                NSLog("[Haynoi] ACTIVATED — held past grace period")
                self.onKeyDown?()
            }
            activationWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay, execute: work)

        } else if !isDown && isModifierDown {
            // Modifier released
            isModifierDown = false
            activationWorkItem?.cancel()
            activationWorkItem = nil

            if isActivated {
                isActivated = false
                NSLog("[Haynoi] RELEASED")
                DispatchQueue.main.async { self.onKeyUp?() }
            } else {
                // Released before grace period — was just a tap/shortcut
                DispatchQueue.main.async { self.onCancelled?() }
            }

        } else if hasOtherModifiers && isModifierDown && !isActivated {
            // Another modifier added — cancel
            isModifierDown = false
            activationWorkItem?.cancel()
            activationWorkItem = nil
            DispatchQueue.main.async { self.onCancelled?() }
        }
    }

    // MARK: - Fix-that tap detection (v1.1)

    /// Detects the configured "fix that" tap and fires `onFixThat`. Pure observer:
    /// reads `flags`/`keyCode` and its own scratch state only, never the
    /// push-to-talk machine. A "tap" = the combo pressed then fully released with
    /// no intervening keyDown, inside `fixTapWindow`.
    private func handleFixThat(_ flags: NSEvent.ModifierFlags, keyCode: UInt16) {
        guard onFixThat != nil, fixThatChoice != "off" else { return }
        // Never refuse a value equal to the push-to-talk modifier (§3.2). The chord
        // default is inherently distinct; only guard double-tap-Option when
        // push-to-talk is Option (the common case), in which case fall back to
        // requiring the chord instead.
        let pttIsOption = (targetModifier == .maskAlternate)

        switch fixThatChoice {
        case "doubleOption" where !pttIsOption:
            detectDoubleOption(flags, keyCode: keyCode)
        case "doubleOption":
            // Push-to-talk owns Option — fall back to the chord so we never
            // collide with dictation.
            detectChord(flags)
        default: // "ctrlOption"
            detectChord(flags)
        }
    }

    /// ⌃⌥ chord tap: both Control and Option down together, then fully released,
    /// no keyDown in between, within the tap window.
    private func detectChord(_ flags: NSEvent.ModifierFlags) {
        let bothDown = flags.contains(.control) && flags.contains(.option)
        // Reject if any disqualifying modifier is also held.
        let extra = flags.intersection([.command, .shift, .function])
        if bothDown && extra.isEmpty {
            if !fixChordArmed {
                fixChordArmed = true
                fixChordArmedAt = Date()
                sawKeyDownSinceChord = false
            }
            return
        }
        // Release path: chord was armed and now at least one of the two is up.
        if fixChordArmed {
            let releasedClean = !flags.contains(.control) || !flags.contains(.option)
            let inWindow = (fixChordArmedAt.map { Date().timeIntervalSince($0) < fixTapWindow }) ?? false
            let wasTap = releasedClean && inWindow && !sawKeyDownSinceChord && extra.isEmpty
            // Fully released (no target/other modifiers left from the chord) → reset.
            if !flags.contains(.control) && !flags.contains(.option) {
                fixChordArmed = false
                fixChordArmedAt = nil
            }
            if wasTap {
                fixChordArmed = false
                fixChordArmedAt = nil
                NSLog("[Haynoi] Fix-that chord tap detected")
                DispatchQueue.main.async { self.onFixThat?() }
            }
        }
    }

    /// ⌥⌥ double-tap of Option (only when push-to-talk is NOT Option).
    private func detectDoubleOption(_ flags: NSEvent.ModifierFlags, keyCode: UInt16) {
        // Count a tap on the RELEASE of a solo Option press.
        let optionUp = !flags.contains(.option)
        let onlyOptionFamily = flags.intersection([.command, .shift, .function, .control]).isEmpty
        guard optionUp, onlyOptionFamily else { return }
        let now = Date()
        if let last = lastOptionTapAt, now.timeIntervalSince(last) < fixTapWindow {
            lastOptionTapAt = nil
            NSLog("[Haynoi] Fix-that double-Option tap detected")
            DispatchQueue.main.async { self.onFixThat?() }
        } else {
            lastOptionTapAt = now
        }
    }
}
