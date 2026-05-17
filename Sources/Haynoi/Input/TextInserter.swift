import AppKit
import ApplicationServices
import UserNotifications

/// Inserts transcribed text into the frontmost app.
/// Strategy: restore focus → clipboard + Cmd+V (most reliable) → AX fallback.
enum TextInserter {

    /// The app that was focused when recording started.
    static var targetApp: NSRunningApplication?

    static func insert(_ text: String) async {
        let axTrusted = AXIsProcessTrusted()
        NSLog("[Haynoi] Insert: AXTrusted=%d, targetApp=%@, text length=%d",
              axTrusted ? 1 : 0,
              targetApp?.bundleIdentifier ?? "nil",
              text.count)

        // Step 0: Wait for ALL modifier keys to be released (Wispr Flow approach)
        // If we paste while Option/Cmd is still held, the target app may ignore it
        await waitForModifierRelease()

        // Step 1: Restore focus to target app
        let focusOK = await restoreFocus()
        NSLog("[Haynoi] Focus restored: %d", focusOK ? 1 : 0)

        // Extra settle time — let target app fully process activation
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        // Step 2: Clipboard + Cmd+V — PRIMARY method (like Wispr Flow)
        // AX insertion "succeeds" on Electron apps (Mandeck, VS Code, Slack, etc.)
        // but text is silently ignored. Cmd+V is the only reliable universal method.
        if axTrusted {
            let pasted = await pasteViaClipboard(text)
            if pasted {
                NSLog("[Haynoi] ✅ Inserted via Cmd+V")
                return
            }
        }

        // Step 3: AX insertion fallback (works for native macOS apps)
        if axTrusted, tryAXInsertion(text) {
            NSLog("[Haynoi] ✅ Inserted via AX")
            return
        }

        // Step 4: Fallback — just put in clipboard and notify
        NSLog("[Haynoi] ⚠️ All insert methods failed, clipboard fallback")
        copyToClipboardWithNotification(text,
            reason: axTrusted
                ? "Auto-paste failed. Press ⌘V to paste."
                : "Grant Accessibility in System Settings."
        )
    }

    // MARK: - Wait for Key Release

    /// Wait until all modifier keys are released before inserting text.
    /// Wispr Flow does this too ("curKeysDown is non-empty on paste").
    /// Without this, paste can fail because the target app sees modifiers held.
    private static func waitForModifierRelease() async {
        let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

        for i in 0..<50 { // max 500ms
            guard let event = CGEvent(source: nil) else { break }
            let currentFlags = event.flags
            let hasModifiers = currentFlags.contains(.maskCommand) ||
                               currentFlags.contains(.maskAlternate) ||
                               currentFlags.contains(.maskControl) ||
                               currentFlags.contains(.maskShift)

            if !hasModifiers {
                if i > 0 {
                    NSLog("[Haynoi] Modifiers released after %dms", i * 10)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        NSLog("[Haynoi] ⚠️ Modifiers still held after 500ms, proceeding anyway")
    }

    // MARK: - Focus Restoration

    private static func restoreFocus() async -> Bool {
        guard let target = targetApp,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return true // no target or target is self
        }

        // Try activate
        target.activate()

        // Poll until frontmost (max 600ms)
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                // Let the app fully process activation
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
                return true
            }
        }

        // Try one more time with options
        target.activate(options: .activateIgnoringOtherApps)
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let actual = NSWorkspace.shared.frontmostApplication
        let match = target.processIdentifier == actual?.processIdentifier
        NSLog("[Haynoi] Focus: target=%@ actual=%@ match=%d",
              target.bundleIdentifier ?? "?",
              actual?.bundleIdentifier ?? "?",
              match ? 1 : 0)
        return match
    }

    // MARK: - AX Direct Insert

    private static func tryAXInsertion(_ text: String) -> Bool {
        guard let app = targetApp ?? NSWorkspace.shared.frontmostApplication else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success else {
            NSLog("[Haynoi] AX: no focused element (error %d) in %@", err.rawValue, app.bundleIdentifier ?? "?")
            return false
        }

        let focused = focusedRef as! AXUIElement

        // Try 1: Set selected text
        let setResult = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            NSLog("[Haynoi] AX: selectedText succeeded")
            return true
        }
        NSLog("[Haynoi] AX: selectedText failed (%d), trying value approach", setResult.rawValue)

        // Try 2: Value + range
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
           AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let currentValue = valueRef as? String {

            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) {
                var newValue = currentValue
                let startIndex = newValue.index(newValue.startIndex, offsetBy: min(range.location, currentValue.count))
                let endIndex = newValue.index(startIndex, offsetBy: min(range.length, currentValue.count - range.location))
                newValue.replaceSubrange(startIndex..<endIndex, with: text)

                if AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success {
                    let newPos = range.location + text.count
                    var newRange = CFRangeMake(newPos, 0)
                    if let axRange = AXValueCreate(.cfRange, &newRange) {
                        AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, axRange)
                    }
                    return true
                }
            }
        }

        NSLog("[Haynoi] AX: all methods failed for %@", app.bundleIdentifier ?? "?")
        return false
    }

    // MARK: - Clipboard + Cmd+V

    private static func pasteViaClipboard(_ text: String) async -> Bool {
        let pb = NSPasteboard.general

        // Set clipboard
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Small delay to let pasteboard sync
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Simulate Cmd+V
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            NSLog("[Haynoi] CGEventSource failed")
            return false
        }

        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else {
            NSLog("[Haynoi] CGEvent creation failed")
            return false
        }

        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)

        // Small gap between key down and up
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)

        NSLog("[Haynoi] Cmd+V posted to .cghidEventTap")

        // Don't restore old clipboard — it races with paste and causes failures.
        // User's clipboard will just have the transcribed text, which is fine.
        return true
    }

    // MARK: - Fallback: Clipboard + Notification

    private static func copyToClipboardWithNotification(_ text: String, reason: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let content = UNMutableNotificationContent()
        content.title = "Haynoi"
        content.subtitle = reason
        content.body = String(text.prefix(100)) + (text.count > 100 ? "…" : "")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "yap-fallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)

        Task { @MainActor in
            AppState.shared.error = "⌘V to paste"
        }
    }
}
