import Carbon
import Cocoa
import CoreGraphics

/// Detects modifier-only hold (default: ⌘ Command) via listenOnly CGEventTap.
///
/// Key insight from Wispr Flow: when modifier is held past the grace period,
/// ALWAYS activate — even if other keys were pressed during the grace period.
/// The user pressed Cmd+T (shortcut) then kept holding Cmd to dictate.
/// Both the shortcut AND dictation should work.
///
/// Uses .listenOnly tap (not active) for maximum compatibility with macOS
/// permission system. Events pass through to apps normally.
///
/// Fix #1: start() now returns Bool and tracks `isActive` state. When Input
/// Monitoring is not yet granted, a retry loop fires every 2.5s and also
/// re-arms on NSApplication.didBecomeActiveNotification so grant-then-switch-
/// back works without a manual relaunch.
///
/// Fix #5: After re-enabling a disabled tap and after the 3s watchdog fires,
/// we resync isModifierDown against the real hardware key state. If the target
/// modifier is no longer physically down, we run the release path to end any
/// stuck recording. The watchdog also checks for secure event input (via the
/// public Carbon API IsSecureEventInputEnabled()) and sets a flag so
/// preRecording can reject silently.

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onModifierDown: (() -> Void)?
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onCancelled: (() -> Void)?

    var targetModifier: CGEventFlags = .maskCommand

    /// Grace period — if modifier held longer than this, activate.
    private let activationDelay: TimeInterval = 0.20

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapCheckTimer: Timer?

    // Fix #1: retry state when permission not yet granted
    private var retryTimer: Timer?
    private var appBecameActiveObserver: NSObjectProtocol?

    private var isModifierDown = false
    private var isActivated = false
    private var activationWorkItem: DispatchWorkItem?

    // Exposed state for AppState / onboarding
    private(set) var isActive = false

    private init() {}

    // MARK: - Setup

    /// Starts the event tap. Returns true if the tap is now live.
    /// If Input Monitoring is not yet granted, schedules a retry loop so the
    /// tap arms automatically once the user grants the permission and returns
    /// to Haynoi — no relaunch needed.
    @discardableResult
    func start() -> Bool {
        stop()

        guard CGPreflightListenEventAccess() else {
            NSLog("[Haynoi] Input Monitoring permission not granted — scheduling retry")
            scheduleRetry()
            isActive = false
            DispatchQueue.main.async { AppState.shared.hotkeyActive = false }
            return false
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                NSLog("[Haynoi] CGEventTap disabled, re-enabling")
                if let tap = mgr.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                // Fix #5: resync after re-enable so stuck recording is cleared.
                // Hop to main so resyncModifierState's precondition is satisfied.
                DispatchQueue.main.async { mgr.resyncModifierState() }
                return Unmanaged.passUnretained(event)
            }

            if type == .flagsChanged {
                let rawFlags = event.flags.rawValue
                DispatchQueue.main.async { mgr.handleFlagsChanged(rawFlags) }
            } else if type == .keyDown {
                // Just for diagnostics — verify tap is alive
                let _ = event.getIntegerValueField(.keyboardEventKeycode)
            }

            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            NSLog("[Haynoi] Failed to create CGEventTap")
            isActive = false
            DispatchQueue.main.async { AppState.shared.hotkeyActive = false }
            // Tap create can fail even after preflight passes (macOS timing) —
            // keep retrying
            scheduleRetry()
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[Haynoi] CGEventTap started (listenOnly, modifier 0x%llx, delay %.0fms)",
              targetModifier.rawValue, activationDelay * 1000)

        isActive = true
        DispatchQueue.main.async { AppState.shared.hotkeyActive = true }

        // Cancel any pending retry — tap is live
        cancelRetry()

        DispatchQueue.main.async {
            self.tapCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self, let tap = self.eventTap else { return }

                // Fix #5: check secure input in the watchdog via the public Carbon
                // API IsSecureEventInputEnabled() (available since macOS 10.4).
                // When a password field or screensaver is active, key events are
                // routed away — starting a recording would capture silence.
                // Reading AppState on main actor; the Timer runs on the main
                // RunLoop so this is safe. Wrapped in Task @MainActor to satisfy
                // the Swift concurrency checker.
                let secureInput = Bool(IsSecureEventInputEnabled())
                Task { @MainActor in
                    if secureInput != AppState.shared.secureInputActive {
                        if secureInput {
                            NSLog("[Haynoi] Secure event input is active — recordings will be blocked")
                        }
                        AppState.shared.secureInputActive = secureInput
                    }
                }

                if !CGEvent.tapIsEnabled(tap: tap) {
                    NSLog("[Haynoi] Re-enabling disabled tap")
                    CGEvent.tapEnable(tap: tap, enable: true)
                    // Fix #5: resync after watchdog re-enables the tap
                    self.resyncModifierState()
                }
            }
        }
        return true
    }

    func stop() {
        tapCheckTimer?.invalidate()
        tapCheckTimer = nil
        cancelRetry()
        activationWorkItem?.cancel()
        activationWorkItem = nil
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
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
            if ok { NSLog("[Haynoi] Event tap armed on retry (no relaunch needed)") }
        }

        // Also retry whenever the app comes back to the foreground — the user
        // may have just granted Input Monitoring and switched back
        if appBecameActiveObserver == nil {
            appBecameActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isActive else { return }
                NSLog("[Haynoi] App became active — retrying event tap")
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

    // MARK: - Modifier Resync (Fix #5)

    /// Reads the ACTUAL hardware modifier state and reconciles with our
    /// internal isModifierDown flag. If we think the modifier is held but it
    /// isn't (e.g. release event was lost during tap disable), synthetically
    /// fire the release path to clear stuck recording state.
    private func resyncModifierState() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isModifierDown else { return }
        guard let event = CGEvent(source: nil) else { return }
        let actuallyDown = event.flags.contains(targetModifier)
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

    private func handleFlagsChanged(_ rawFlags: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        let targetRaw = targetModifier.rawValue
        let isDown = (rawFlags & targetRaw) != 0

        // Check no other modifiers are pressed
        let allModifiers: UInt64 =
            CGEventFlags.maskCommand.rawValue |
            CGEventFlags.maskAlternate.rawValue |
            CGEventFlags.maskControl.rawValue |
            CGEventFlags.maskShift.rawValue
        let otherModifiers = (rawFlags & allModifiers) & ~targetRaw
        let hasOtherModifiers = otherModifiers != 0

        if isDown && !isModifierDown && !hasOtherModifiers {
            // Modifier pressed
            isModifierDown = true
            activationWorkItem?.cancel()

            // Start mic immediately
            DispatchQueue.main.async { self.onModifierDown?() }

            // After grace period: if modifier STILL held → activate
            // Don't care about keyDown events — shortcuts pass through normally
            // with listenOnly tap, user gets both shortcut AND dictation
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
