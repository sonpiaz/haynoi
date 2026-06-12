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

    /// Public API kept as CGEventFlags so SettingsView's hotkey picker keeps
    /// working unchanged. Internally we translate to NSEvent.ModifierFlags.
    var targetModifier: CGEventFlags = .maskCommand

    /// Grace period — if modifier held longer than this, activate.
    private let activationDelay: TimeInterval = 0.20

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
            DispatchQueue.main.async { self.handleFlagsChanged(flags) }
        case .keyDown:
            // Just for diagnostics — verify the monitor is alive. The old
            // onKeyDown semantics ("other key pressed") no longer gate
            // activation: holding the modifier past the grace period always
            // activates, exactly as the CGEventTap path behaved.
            break
        default:
            break
        }
    }

    private func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        dispatchPrecondition(condition: .onQueue(.main))
        let isDown = flags.contains(targetFlag)

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
}
