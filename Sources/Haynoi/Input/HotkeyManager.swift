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

    private var isModifierDown = false
    private var isActivated = false
    private var activationWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - Setup

    func start() {
        stop()

        guard CGPreflightListenEventAccess() else {
            NSLog("[Haynoi] Input Monitoring permission not granted")
            return
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
                return Unmanaged.passUnretained(event)
            }

            if type == .flagsChanged {
                mgr.handleFlagsChanged(event.flags.rawValue)
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
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[Haynoi] CGEventTap started (listenOnly, modifier 0x%llx, delay %.0fms)",
              targetModifier.rawValue, activationDelay * 1000)

        DispatchQueue.main.async {
            self.tapCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self, let tap = self.eventTap else { return }
                if !CGEvent.tapIsEnabled(tap: tap) {
                    NSLog("[Haynoi] Re-enabling disabled tap")
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
        }
    }

    func stop() {
        tapCheckTimer?.invalidate()
        tapCheckTimer = nil
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
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(_ rawFlags: UInt64) {
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
