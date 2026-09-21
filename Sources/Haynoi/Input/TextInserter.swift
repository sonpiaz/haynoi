import AppKit
import ApplicationServices
import Carbon
import UserNotifications

/// Inserts transcribed text into the frontmost app.
/// Strategy: restore focus → verify AX target → Cmd+V (most reliable) → AX fallback.
enum TextInserter {

    /// Result of an insertion. `span` is the UTF-16 (location, length) range the
    /// inserted text occupied in the focused field, when knowable (AX paths); nil
    /// for the clipboard fallback in non-AX apps (Electron). v1.1 uses it to
    /// later select-and-replace the same span for an in-place "fix that".
    struct InsertionResult {
        let inserted: String
        let span: NSRange?
        let targetApp: NSRunningApplication?
    }

    // Fix #9: targetApp is now a per-dictation parameter; this static is removed.
    // Kept only as a migration shim used by legacy callers that haven't updated yet.
    // PipelineController captures and passes it explicitly since Batch B.

    // Fix #8: cached virtual key for 'v' resolved from the current keyboard layout.
    // Populated lazily; reset to nil when the layout changes.
    private static var cachedVKeyCode: CGKeyCode?

    // MARK: - Insert Entry Point

    /// Inserts text into `targetApp` (the app that was frontmost when recording started).
    /// Passing targetApp explicitly (Fix #9) prevents the shared-static race.
    @discardableResult
    static func insert(_ text: String, targetApp: NSRunningApplication?) async -> InsertionResult {
        let axTrusted = AXIsProcessTrusted()
        NSLog("[Haynoi] Insert: AXTrusted=%d, targetApp=%@, text length=%d",
              axTrusted ? 1 : 0,
              targetApp?.bundleIdentifier ?? "nil",
              text.count)

        // Step 0: Wait for ALL modifier keys to be released (Wispr Flow approach)
        // If we paste while Option/Cmd is still held, the target app may ignore it.
        // Fix #9: ceiling raised to 10s; give-up path uses clipboard+notification.
        let modifiersCleared = await waitForModifierRelease()
        if !modifiersCleared {
            NSLog("[Haynoi] ⚠️ Modifiers still held after ceiling — clipboard fallback")
            copyToClipboardWithNotification(text, reason: "Press ⌘V to paste.")
            return InsertionResult(inserted: text, span: nil, targetApp: targetApp)
        }

        // Step 1: Restore focus to target app.
        // Fix #1: if focus restore fails, skip synthetic paste entirely.
        let (focusOK, didSwitch) = await restoreFocus(targetApp: targetApp)
        NSLog("[Haynoi] Focus restored: %d (didSwitch=%d)", focusOK ? 1 : 0, didSwitch ? 1 : 0)

        if !focusOK {
            NSLog("[Haynoi] ⚠️ Focus restore failed — clipboard fallback to avoid wrong-app paste")
            copyToClipboardWithNotification(text, reason: "Press ⌘V to paste.")
            return InsertionResult(inserted: text, span: nil, targetApp: targetApp)
        }

        // Extra settle time — let target app fully process activation.
        // If no app switch happened the target was already frontmost — 50ms is enough.
        // After a real switch give the full 150ms so the app can process activation.
        let settleNs: UInt64 = didSwitch ? 150_000_000 : 50_000_000
        try? await Task.sleep(nanoseconds: settleNs)

        // Fix #1: last-instant check — confirm the correct app is still frontmost.
        let frontmost = NSWorkspace.shared.frontmostApplication
        switch pasteGate(targetPID: targetApp?.processIdentifier,
                         frontmostPID: frontmost?.processIdentifier,
                         frontmostIsHaynoi: frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier) {
        case .go:
            break
        case .blockWrongApp:
            NSLog("[Haynoi] ⚠️ Frontmost mismatch after settle (%@ vs %@) — clipboard fallback",
                  frontmost?.bundleIdentifier ?? "?",
                  targetApp?.bundleIdentifier ?? "?")
            copyToClipboardWithNotification(text, reason: "Press ⌘V to paste.")
            return InsertionResult(inserted: text, span: nil, targetApp: targetApp)
        case .blockUnknownTarget:
            NSLog("[Haynoi] ⚠️ No target app and Haynoi is frontmost — clipboard fallback")
            copyToClipboardWithNotification(text, reason: "Press ⌘V to paste.")
            return InsertionResult(inserted: text, span: nil, targetApp: targetApp)
        }

        // What the paste attempt left on the clipboard, read by the fallback below.
        var pasteAttempt: PasteAttempt = .notTakenNothingLeft

        // Step 2: Clipboard + Cmd+V — PRIMARY method (like Wispr Flow)
        // AX insertion "succeeds" on Electron apps (Mandeck, VS Code, Slack, etc.)
        // but text is silently ignored. Cmd+V is the only reliable universal method.
        if axTrusted {
            // Snapshot the caret position BEFORE paste so we can derive the span
            // it occupied (caret-after − text length) for an in-place "fix that".
            let preCaret = focusedSelectionRange(in: targetApp ?? NSWorkspace.shared.frontmostApplication)
            switch await pasteViaClipboard(text, targetApp: targetApp) {
            case .taken:
                NSLog("[Haynoi] Insert via Cmd+V")
                // The paste now returns as soon as the app takes the text, which can
                // be before it has drawn it. Keep the caret on the same budget it had
                // before (300ms after ⌘V) or the derived span used by "fix that"
                // would be read too early.
                try? await Task.sleep(nanoseconds: 300_000_000)
                let span = pasteSpan(preCaret: preCaret, text: text, targetApp: targetApp)
                return InsertionResult(inserted: text, span: span, targetApp: targetApp)
            case let outcome:
                pasteAttempt = outcome
            }
        }

        // Step 3: AX insertion fallback (works for native macOS apps)
        if axTrusted {
            let app = targetApp ?? frontmost
            let beforeAX = focusedElementValue(in: app)
            let axSpan = tryAXInsertionReturningSpan(text, targetApp: targetApp)
            if axSpan != nil {
                // Read the field back only after it has had a moment to update, or a
                // real insertion looks like a failed one and the user is told to
                // press ⌘V over text that is already there.
                try? await Task.sleep(nanoseconds: axSettleNs)
            }
            if let span = axSpan, axInsertionLanded(before: beforeAX, after: focusedElementValue(in: app)) {
                NSLog("[Haynoi] Insert via AX")
                // The field really changed, so the clipboard does not have to carry
                // the sentence any more: give the user back whatever they copied.
                if case .notTakenTextKept(let restoreUserClipboard) = pasteAttempt {
                    restoreUserClipboard()
                }
                // span may be NSRange(location: NSNotFound, ...) when AX inserted
                // but the location was unknown (selectedText path). Normalize.
                let usable = span.location == NSNotFound ? nil : span
                return InsertionResult(inserted: text, span: usable, targetApp: targetApp)
            }
            if axSpan != nil {
                NSLog("[Haynoi] AX reported success but the field change could not be confirmed — not trusting it")
            }
        }

        // Step 4: Fallback — put in clipboard and notify
        NSLog("[Haynoi] All insert methods failed, clipboard fallback")
        switch pasteAttempt {
        case .notTakenTextKept:
            // The paste path already left the sentence on the clipboard.
            // AX may have inserted after all — we could not read the field to know —
            // so this must not claim the text is missing, or ⌘V pastes it twice.
            notifyFallback(text, reason: "Press ⌘V if the text did not land.")
        case .notTakenClipboardIsTheirs:
            // The user copied something while we were pasting — never clobber it.
            notifyFallback(text,
                           reason: "Your copy was kept — the sentence is in Haynoi's history.",
                           banner: "Kept your copy — sentence in History")
        default:
            // With accessibility granted this path has still been through the AX
            // write, which can insert without letting us confirm it — so it says
            // "if", the same as the case above. Without it, nothing was tried.
            copyToClipboardWithNotification(text,
                reason: axTrusted
                    ? "Press ⌘V if the text did not land."
                    : "Grant Accessibility in System Settings."
            )
        }
        return InsertionResult(inserted: text, span: nil, targetApp: targetApp)
    }

    /// Whether an AX insertion actually put the text in the field.
    ///
    /// A `.success` from the AX write is not evidence: on Electron apps the write
    /// succeeds and the text is silently dropped, and in terminals the value cannot
    /// be read at all. Only a field whose value changed counts; anything else falls
    /// through to the clipboard-and-notify path, so a sentence is never taken off
    /// the clipboard on the strength of an insertion that may not have happened.
    static func axInsertionLanded(before: String?, after: String?) -> Bool {
        guard let before, let after else { return false }
        return before != after
    }

    /// Whether a synthetic ⌘V may be posted. It goes to whatever app is up front,
    /// so the app we recorded against must still be that app — and when no app was
    /// captured at all, it must at least not be Haynoi itself, or the sentence would
    /// be pasted into our own window and lost (2 of the last 500 dictations had no
    /// captured target).
    enum PasteGate: Equatable { case go, blockWrongApp, blockUnknownTarget }

    static func pasteGate(targetPID: pid_t?, frontmostPID: pid_t?, frontmostIsHaynoi: Bool) -> PasteGate {
        if let target = targetPID {
            return target == frontmostPID ? .go : .blockWrongApp
        }
        return frontmostIsHaynoi ? .blockUnknownTarget : .go
    }

    /// Derive the inserted span after a successful clipboard paste: read the
    /// post-paste caret (sits at end-of-paste); `span = (caret − len, len)`.
    /// Returns nil when AX caret read is unavailable (Electron) — span unknown.
    private static func pasteSpan(preCaret: CFRange?, text: String, targetApp: NSRunningApplication?) -> NSRange? {
        guard let post = focusedSelectionRange(in: targetApp ?? NSWorkspace.shared.frontmostApplication) else {
            return nil
        }
        let len = text.utf16.count
        let caret = post.location
        let loc = caret - len
        guard loc >= 0 else { return nil }
        return NSRange(location: loc, length: len)
    }

    // MARK: - Wait for Key Release (Fix #9)

    /// Wait until all modifier keys are released before inserting text.
    /// Fix #9: ceiling raised to 10s; returns false if ceiling hit (caller uses clipboard fallback).
    @discardableResult
    private static func waitForModifierRelease() async -> Bool {
        // 10 second ceiling, checked every 10ms = 1000 iterations.
        for i in 0..<1000 {
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
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        NSLog("[Haynoi] Modifiers still held after 10s ceiling")
        return false
    }

    // MARK: - Focus Restoration

    /// Returns (focusOK, didSwitch).
    /// didSwitch is false when the target was already frontmost — the caller can use a
    /// shorter settle delay in that case, shaving ~100ms off the no-switch hot path.
    private static func restoreFocus(targetApp: NSRunningApplication?) async -> (Bool, Bool) {
        guard let target = targetApp,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return (true, false) // no target or target is self — nothing to switch
        }

        // Fast path: target is already frontmost — skip activate() and all polling.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            NSLog("[Haynoi] Focus: target already frontmost, skipping activate")
            return (true, false)
        }

        // Slow path: target is not frontmost — activate and poll.
        target.activate()

        // Poll until frontmost (max 600ms)
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                // Let the app fully process activation
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
                return (true, true)
            }
        }

        // Try one more time with no options (activateIgnoringOtherApps is a no-op
        // on macOS 14+ and emits a deprecation warning).
        target.activate(options: [])
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let actual = NSWorkspace.shared.frontmostApplication
        let match = target.processIdentifier == actual?.processIdentifier
        NSLog("[Haynoi] Focus: target=%@ actual=%@ match=%d",
              target.bundleIdentifier ?? "?",
              actual?.bundleIdentifier ?? "?",
              match ? 1 : 0)
        return (match, match) // didSwitch only true if we actually succeeded
    }

    // MARK: - AX Direct Insert (Fix #4)

    /// AX direct insert. Returns the UTF-16 span the inserted text now occupies,
    /// or nil if all AX paths failed. When the selectedText path succeeds but the
    /// pre-insert caret was unknown, the returned span has `location == NSNotFound`
    /// (length set), signalling "inserted, location unknown" to the caller.
    ///
    /// A span is not proof the text arrived: the write succeeds on apps that drop
    /// it. Callers check `axInsertionLanded` before believing it.
    private static func tryAXInsertionReturningSpan(_ text: String, targetApp: NSRunningApplication?) -> NSRange? {
        guard let app = targetApp ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success else {
            NSLog("[Haynoi] AX: no focused element (error %d) in %@", err.rawValue, app.bundleIdentifier ?? "?")
            return nil
        }

        let focused = focusedRef as! AXUIElement

        // Try 1: Set selected text. Capture the caret BEFORE so we know where the
        // text landed (caret replaces selection with text → starts at caret loc).
        var preRangeRef: CFTypeRef?
        var preLoc = NSNotFound
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &preRangeRef) == .success {
            var pre = CFRange()
            if AXValueGetValue(preRangeRef as! AXValue, .cfRange, &pre) {
                preLoc = pre.location
            }
        }
        let setResult = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            NSLog("[Haynoi] AX: selectedText succeeded")
            let loc = preLoc == NSNotFound ? NSNotFound : preLoc
            return NSRange(location: loc, length: text.utf16.count)
        }
        NSLog("[Haynoi] AX: selectedText failed (%d), trying value approach", setResult.rawValue)

        // Try 2: Value + range splice — Fix #4: done in UTF-16 space to handle emoji
        // and Vietnamese combining characters without Swift Character index traps.
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
           AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let currentValue = valueRef as? String {

            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) {
                let utf16 = currentValue.utf16
                let utf16Count = utf16.count

                // Fix #4: clamp AX (UTF-16) range into [0, utf16Count] to avoid index traps.
                let safeLocation = max(0, min(range.location, utf16Count))
                let maxLength = utf16Count - safeLocation
                let safeLength = max(0, min(range.length, maxLength))

                // Bail if range is nonsensical (out-of-bounds input from AX).
                guard safeLocation >= 0, safeLocation <= utf16Count,
                      safeLength >= 0, safeLength <= utf16Count - safeLocation else {
                    NSLog("[Haynoi] AX: range out of bounds (loc=%d, len=%d, utf16Count=%d)",
                          range.location, range.length, utf16Count)
                    return nil
                }

                // Build new string in UTF-16 space.
                let startIdx = utf16.index(utf16.startIndex, offsetBy: safeLocation)
                let endIdx = utf16.index(startIdx, offsetBy: safeLength)

                // Reconstruct as a full Swift String.
                var newUTF16 = Array(utf16)
                let textUTF16 = Array(text.utf16)
                let replaceStart = utf16.distance(from: utf16.startIndex, to: startIdx)
                let replaceEnd = utf16.distance(from: utf16.startIndex, to: endIdx)
                newUTF16.replaceSubrange(replaceStart..<replaceEnd, with: textUTF16)
                let newValue = String(decoding: newUTF16, as: UTF16.self)

                if AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success {
                    // Move cursor to end of inserted text (UTF-16 position).
                    let newPos = safeLocation + text.utf16.count
                    var newRange = CFRangeMake(newPos, 0)
                    if let axRange = AXValueCreate(.cfRange, &newRange) {
                        AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, axRange)
                    }
                    return NSRange(location: safeLocation, length: text.utf16.count)
                }
            }
        }

        NSLog("[Haynoi] AX: all methods failed for %@", app.bundleIdentifier ?? "?")
        return nil
    }

    /// Reads the focused element's selected text range (caret/selection) as a
    /// CFRange in UTF-16 space. Returns nil when AX is unavailable.
    private static func focusedSelectionRange(in app: NSRunningApplication?) -> CFRange? {
        AXRead.focusedSelection(in: app)
    }

    // MARK: - Shared AX reader (v1.3 — single source of truth)

    /// The one place that touches the Accessibility C-API for *reading* the
    /// focused element. `TextInserter`'s legacy private helpers delegate here so
    /// there is a single source of truth; `CorrectionWatcher` (Signal A) reads
    /// through it too. Read-only — never mutates the focused element. Behavior of
    /// insert / replaceSpan is unchanged: the old method bodies moved verbatim.
    enum AXRead {
        /// The focused UI element of `app`, or nil when AX is unavailable / denied.
        private static func focusedElement(in app: NSRunningApplication?) -> AXUIElement? {
            guard let app else { return nil }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                let ref = focusedRef else { return nil }
            return (ref as! AXUIElement)
        }

        /// Current AXValue string of the focused element, or nil.
        static func focusedValue(in app: NSRunningApplication?) -> String? {
            guard let focused = focusedElement(in: app) else { return nil }
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                focused, kAXValueAttribute as CFString, &valueRef) == .success,
                let str = valueRef as? String else { return nil }
            return str
        }

        /// Selected text range (caret/selection) as a UTF-16 CFRange, or nil.
        static func focusedSelection(in app: NSRunningApplication?) -> CFRange? {
            guard let focused = focusedElement(in: app) else { return nil }
            var rangeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else {
                return nil
            }
            var range = CFRange()
            guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
            return range
        }

        /// (role, value) of the focused element in one read. Either field may be nil;
        /// the tuple itself is nil only when there is no focused element at all.
        static func focusedRoleAndValue(in app: NSRunningApplication?) -> (role: String?, value: String?)? {
            guard let focused = focusedElement(in: app) else { return nil }
            var roleRef: CFTypeRef?
            let role = AXUIElementCopyAttributeValue(
                focused, kAXRoleAttribute as CFString, &roleRef) == .success
                ? (roleRef as? String) : nil
            var valueRef: CFTypeRef?
            let value = AXUIElementCopyAttributeValue(
                focused, kAXValueAttribute as CFString, &valueRef) == .success
                ? (valueRef as? String) : nil
            return (role, value)
        }

        /// True when the focused element is a secure (password) text field. Checks
        /// both role and subrole == AXSecureTextField. PRIVACY: callers MUST bail
        /// before reading any value when this returns true.
        static func isFocusedSecure(in app: NSRunningApplication?) -> Bool {
            guard let focused = focusedElement(in: app) else { return false }
            let secure = "AXSecureTextField"
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                focused, kAXRoleAttribute as CFString, &roleRef) == .success,
                (roleRef as? String) == secure { return true }
            var subRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                focused, kAXSubroleAttribute as CFString, &subRef) == .success,
                (subRef as? String) == secure { return true }
            return false
        }
    }

    // MARK: - In-place replace (v1.1 "fix that")

    /// Replaces the text occupying `span` in the target app with `newText`
    /// (redesign §6). Primary path: AX selection-set the old span then set
    /// selected text. Fallbacks A (value splice over span) / B (select + paste
    /// over selection). Fallback C (span unknown): insert at the cursor — never a
    /// synthetic backspace-delete (IME/combining-char unsafe). Returns true when
    /// the OLD text was actually replaced in place; false means the correction was
    /// inserted at the cursor and the old text still remains (caller surfaces a
    /// quiet status). Never crashes, never double-inserts.
    @discardableResult
    static func replaceSpan(
        _ span: NSRange?,
        with newText: String,
        oldText: String,
        targetApp: NSRunningApplication?,
        fallbackInsert: Bool = true
    ) async -> Bool {
        let axTrusted = AXIsProcessTrusted()

        // Wait for modifiers + restore focus, mirroring the insert path.
        _ = await waitForModifierRelease()
        let (focusOK, didSwitch) = await restoreFocus(targetApp: targetApp)
        if focusOK {
            let settleNs: UInt64 = didSwitch ? 150_000_000 : 50_000_000
            try? await Task.sleep(nanoseconds: settleNs)
        }

        // Fallback C — span unknown (Electron / non-AX). Don't try to select the
        // old text. Insert the correction at the cursor; the old text remains.
        guard let span, span.location != NSNotFound, axTrusted, focusOK else {
            NSLog("[Haynoi] replaceSpan: span unknown / AX unavailable — inserting at cursor")
            return await fallbackOrSkip(newText, targetApp: targetApp, fallbackInsert: fallbackInsert)
        }

        guard let app = targetApp ?? NSWorkspace.shared.frontmostApplication else {
            return await fallbackOrSkip(newText, targetApp: targetApp, fallbackInsert: fallbackInsert)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            return await fallbackOrSkip(newText, targetApp: targetApp, fallbackInsert: fallbackInsert)
        }
        let focused = focusedRef as! AXUIElement

        // Safety gate (blocker + major fix): before touching the span, confirm the
        // focused element STILL holds the user's old text at exactly that span.
        // The span is a UTF-16 snapshot from insert time; up to ~60s may have
        // passed during which the user could type, delete, scroll, or click into a
        // DIFFERENT field in the same app (restoreFocus only re-activates the app,
        // not the element). If the bytes at the span no longer equal oldText, a
        // positional select/splice would clobber unrelated content — silent data
        // loss. Verifying value[span] == oldText (NFC-normalized) implicitly
        // catches the wrong-field case too, since the bytes won't match.
        guard let currentValue = focusedElementValue(in: app) else {
            // Can't read the value to verify — don't risk a blind positional write.
            NSLog("[Haynoi] replaceSpan: cannot read focused value to verify span — inserting at cursor")
            return await fallbackOrSkip(newText, targetApp: targetApp, fallbackInsert: fallbackInsert)
        }
        let valueUTF16 = Array(currentValue.utf16)
        guard span.length >= 0,
              span.location >= 0,
              span.location + span.length <= valueUTF16.count else {
            // Span points past the end of the current value (field changed / shrank
            // / wrong element). Bail to insert-at-cursor.
            NSLog("[Haynoi] replaceSpan: span out of bounds (loc=%d len=%d count=%d) — inserting at cursor",
                  span.location, span.length, valueUTF16.count)
            return await fallbackOrSkip(newText, targetApp: targetApp, fallbackInsert: fallbackInsert)
        }
        let spanText = String(decoding: valueUTF16[span.location..<(span.location + span.length)], as: UTF16.self)
        guard spanText.precomposedStringWithCanonicalMapping
                == oldText.precomposedStringWithCanonicalMapping else {
            // The text under the span is no longer the user's old text — replacing
            // would destroy whatever now occupies those offsets.
            NSLog("[Haynoi] replaceSpan: span no longer matches oldText — inserting at cursor")
            return await fallbackOrSkip(newText, targetApp: targetApp, fallbackInsert: fallbackInsert)
        }

        // Set the selection to the old span.
        var cfSpan = CFRangeMake(span.location, span.length)
        guard let axSpan = AXValueCreate(.cfRange, &cfSpan) else {
            return await fallbackOrSkip(newText, targetApp: targetApp, fallbackInsert: fallbackInsert)
        }
        let selSet = AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, axSpan)

        // Primary — set selected text over the now-selected old span.
        if selSet == .success {
            let r = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, newText as CFTypeRef)
            if r == .success {
                NSLog("[Haynoi] replaceSpan: AX selectedText replace OK")
                return true
            }
            NSLog("[Haynoi] replaceSpan: setSelectedText failed (%d), trying value splice", r.rawValue)
        }

        // Fallback A — value splice over the explicit span (selection set may or
        // may not have worked; splice uses the span directly).
        if let value = focusedElementValue(in: app) {
            let utf16 = Array(value.utf16)
            let count = utf16.count
            let loc = max(0, min(span.location, count))
            let len = max(0, min(span.length, count - loc))
            var newArr = utf16
            newArr.replaceSubrange(loc..<(loc + len), with: Array(newText.utf16))
            let newValue = String(decoding: newArr, as: UTF16.self)
            if AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success {
                let newPos = loc + newText.utf16.count
                var nr = CFRangeMake(newPos, 0)
                if let r = AXValueCreate(.cfRange, &nr) {
                    AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, r)
                }
                NSLog("[Haynoi] replaceSpan: AX value splice OK")
                return true
            }
        }

        // Fallback B — selection set worked but setSelectedText didn't: paste over
        // the selection (Cmd+V replaces the selected old text).
        if selSet == .success {
            switch await pasteViaClipboard(newText, targetApp: targetApp) {
            case .taken:
                NSLog("[Haynoi] replaceSpan: paste-over-selection OK")
                return true
            case .notTakenTextKept(let restoreUserClipboard):
                // Whatever happens next inserts the correction another way and takes
                // its own snapshot of the clipboard. Put the user's copy back first,
                // or that snapshot preserves our correction instead of their copy.
                restoreUserClipboard()
            case .notTakenClipboardIsTheirs, .notTakenNothingLeft:
                break
            }
        }

        // Could not replace in place — insert at cursor (old text remains).
        NSLog("[Haynoi] replaceSpan: all in-place paths failed — inserting at cursor")
        return await fallbackOrSkip(newText, targetApp: targetApp, fallbackInsert: fallbackInsert)
    }

    /// Cloud follow-up must never insert a second copy. Correction still may.
    private static func fallbackOrSkip(
        _ newText: String,
        targetApp: NSRunningApplication?,
        fallbackInsert: Bool
    ) async -> Bool {
        if fallbackInsert {
            _ = await insert(newText, targetApp: targetApp)
        }
        return false
    }

    // MARK: - Clipboard + Cmd+V (Fix #2, #3, #8)

    /// Evidence that the keystroke turned into a real request for our text.
    ///
    /// The sentence goes onto the pasteboard *lazily*: macOS calls this back when a
    /// reader asks for the data — which is what an app does while handling ⌘V. It
    /// does not say who asked, and measured in a background app it can fire while
    /// the app is working out whether it can paste at all, so it proves the text was
    /// handed out, not that it is in the box. It is still the only evidence available
    /// across apps: AX is blind in terminals (Mandeck exposes no text element at all,
    /// so the old pre/post value check compared nil to nil and reported success for
    /// every paste, including the ones that never arrived — whose text the restore
    /// timer then wiped off the clipboard).
    ///
    /// Measured: the pasteboard server caches the data after the first callback, so
    /// an app that reads twice while handling one ⌘V (Mandeck asks for file URLs,
    /// then the terminal asks for the string) gets the same text both times and the
    /// callback fires once.
    final class PasteReceipt: NSObject, NSPasteboardItemDataProvider {
        private let text: String
        private let lock = NSLock()
        private var served = false

        init(_ text: String) { self.text = text }

        var wasServed: Bool {
            lock.lock(); defer { lock.unlock() }
            return served
        }

        func pasteboard(_ pasteboard: NSPasteboard?,
                        item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            lock.lock()
            served = true
            lock.unlock()
            item.setString(text, forType: type)
        }
    }

    /// One attempt, one keystroke. A timeout proves nobody has read the clipboard
    /// *yet*, never that the first ⌘V was discarded, so a second one can paste the
    /// same sentence twice when both were merely queued behind a busy app.
    /// `postCommandV` spends the budget itself and refuses once it is spent, so a
    /// second post has to be a deliberate change to this type — not a slip.
    struct KeystrokeBudget {
        private var spent = false

        mutating func take() -> Bool {
            if spent { return false }
            spent = true
            return true
        }
    }

    /// How long to wait for someone to read the clipboard before giving up on the
    /// paste. There is no second ⌘V: a timeout proves nobody has read the clipboard
    /// *yet*, never that the first keystroke was discarded, so a retry could paste
    /// the same sentence twice when both events were merely queued.
    private static let receiptWaitNs: UInt64 = 1_500_000_000
    /// How long the field gets to update before we read it back to see whether an
    /// AX insertion really landed.
    private static let axSettleNs: UInt64 = 80_000_000
    /// Grace before the user's clipboard goes back. A read proves the app asked for
    /// the text, not that the text is in the box, so the sentence stays available to
    /// a manual ⌘V for a couple of seconds either way.
    private static let restoreGraceNs: UInt64 = 2_000_000_000

    /// What a paste attempt left behind, so the fallback knows whether it may write
    /// to the clipboard.
    enum PasteAttempt {
        /// Someone read the clipboard after ⌘V.
        case taken
        /// Nobody read it; the sentence is on the clipboard for a manual ⌘V.
        /// `restoreUserClipboard` puts the user's own clipboard back, for the caller
        /// that manages to insert the sentence another way.
        case notTakenTextKept(restoreUserClipboard: () -> Void)
        /// Nobody read it, and the user copied something while we waited — their
        /// copy stays, the sentence stays in the history.
        case notTakenClipboardIsTheirs
        /// The paste never got off the ground; the clipboard is untouched.
        case notTakenNothingLeft
    }

    private static func pasteViaClipboard(_ text: String, targetApp: NSRunningApplication?) async -> PasteAttempt {
        let pb = NSPasteboard.general

        // Fix #2: check for a focused text element before investing in a paste.
        // If AX reports no settable/readable text element, note it and paste anyway —
        // terminals and Electron apps report nothing and still paste fine.
        if let app = targetApp ?? NSWorkspace.shared.frontmostApplication {
            if !hasFocusedTextElement(in: app) {
                NSLog("[Haynoi] AX: no focused text element in %@, proceeding with Cmd+V",
                      app.bundleIdentifier ?? "?")
            }
        }

        // Fix #3: snapshot existing pasteboard contents before we overwrite.
        let savedItems = snapshotPasteboard(pb)
        let preWriteChangeCount = pb.changeCount

        // Write our text lazily (see PasteReceipt) so we learn when the target takes it.
        // The receipt must outlive its item on the pasteboard: releasing the provider
        // makes macOS fulfil the promise on the spot (measured), which hands out the
        // text early and marks the receipt read. Every path below either keeps it
        // alive or has already replaced the item.
        let receipt = PasteReceipt(text)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(receipt, forTypes: [.string])
        // Fix #3: ConcealedType tells clipboard managers (Alfred, Paste, etc.) to skip this entry.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.writeObjects([item])
        let postWriteChangeCount = pb.changeCount

        NSLog("[Haynoi] Pasteboard written (changeCount %d→%d)", preWriteChangeCount, postWriteChangeCount)

        // Small delay to let pasteboard sync.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        var budget = KeystrokeBudget()
        guard await postCommandV(spending: &budget) else {
            restorePasteboard(pb, items: savedItems, writtenChangeCount: postWriteChangeCount)
            return .notTakenNothingLeft
        }

        if await waitForReceipt(receipt, timeout: receiptWaitNs) {
            NSLog("[Haynoi] Clipboard read after ⌘V")
            let restoreChangeCount = postWriteChangeCount
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: restoreGraceNs)
                restorePasteboard(NSPasteboard.general, items: savedItems, writtenChangeCount: restoreChangeCount)
                withExtendedLifetime(receipt) {}
            }
            return .taken
        }

        // Nobody asked for the text inside the window, so as far as anything here can
        // tell, the paste never happened. Leave the sentence on the clipboard for a
        // manual ⌘V instead of restoring over it — restoring 400ms after every ⌘V,
        // read or not, is what used to make a failed paste unrecoverable.
        NSLog("[Haynoi] Clipboard never read — leaving text for a manual paste")
        guard leaveTextForManualPaste(text, on: pb, ourChangeCount: postWriteChangeCount) else {
            return .notTakenClipboardIsTheirs
        }
        let ourChangeCount = pb.changeCount
        return .notTakenTextKept(restoreUserClipboard: {
            // Called only if another path puts the sentence in for us after all, so
            // the clipboard does not have to carry it any more.
            restorePasteboard(NSPasteboard.general, items: savedItems, writtenChangeCount: ourChangeCount)
        })
    }

    /// Materialises the dictated sentence on the clipboard so ⌘V works, and works
    /// twice. If the user copied something while the paste was pending the clipboard
    /// is no longer ours: their copy stays, and the sentence stays in the history.
    /// Returns whether the sentence is on the clipboard.
    @discardableResult
    static func leaveTextForManualPaste(_ text: String, on pb: NSPasteboard, ourChangeCount: Int) -> Bool {
        guard pb.changeCount == ourChangeCount else {
            NSLog("[Haynoi] Clipboard was taken over while pasting — keeping the user's copy")
            return false
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        return true
    }

    /// Polls the receipt until the target reads the clipboard or the window closes.
    private static func waitForReceipt(_ receipt: PasteReceipt, timeout: UInt64) async -> Bool {
        let step: UInt64 = 20_000_000 // 20ms
        var waited: UInt64 = 0
        while waited < timeout {
            if receipt.wasServed { return true }
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
        return receipt.wasServed
    }

    /// Posts ⌘V at the HID tap. Returns false when the budget is already spent or
    /// the event could not be built.
    private static func postCommandV(spending budget: inout KeystrokeBudget) async -> Bool {
        guard budget.take() else {
            NSLog("[Haynoi] Refusing a second ⌘V for one dictation")
            return false
        }

        // Fix #8: resolve 'v' keycode from current keyboard layout at runtime.
        let vKeyCode = resolveVKeyCode()

        guard let src = CGEventSource(stateID: .hidSystemState) else {
            NSLog("[Haynoi] CGEventSource failed")
            return false
        }

        // Posting a synthetic event makes macOS filter the user's OWN input for
        // localEventsSuppressionInterval — measured at 0.250s, with the default
        // filter permitting *nothing*. Two posts 20ms apart chain into ~270ms
        // in which the mouse wheel is dead, which reads as "scrolling is
        // frozen" right after every dictation. Let the user's mouse through.
        //
        // Keyboard stays filtered on purpose: the paste posts key-down and
        // key-up 20ms apart, both carrying .maskCommand, so a real keystroke
        // landing between them could be read as a ⌘-shortcut.
        for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval,
                      CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag] {
            src.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitSystemDefinedEvents],
                state: state
            )
        }

        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false) else {
            NSLog("[Haynoi] CGEvent creation failed")
            return false
        }

        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)

        // Small gap between key down and up.
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)

        NSLog("[Haynoi] Cmd+V posted (keyCode=0x%02X)", vKeyCode)
        return true
    }

    // MARK: - Pasteboard Snapshot / Restore (Fix #3)

    /// Copies all items from the pasteboard into memory across common types.
    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        let types: [NSPasteboard.PasteboardType] = [
            .string, .rtf, .rtfd, .html,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("public.url"),
        ]
        var copies: [NSPasteboardItem] = []
        for original in pb.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            if !copy.types.isEmpty {
                copies.append(copy)
            }
        }
        return copies
    }

    /// Restores the previously snapshotted pasteboard, but only if nobody else
    /// has written to it in the meantime (changeCount guard).
    static func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem], writtenChangeCount: Int) {
        // If changeCount advanced beyond what we wrote, another app wrote — don't clobber.
        guard pb.changeCount == writtenChangeCount else {
            NSLog("[Haynoi] Pasteboard changed externally (count %d vs %d), skipping restore",
                  pb.changeCount, writtenChangeCount)
            return
        }
        guard !items.isEmpty else {
            pb.clearContents()
            NSLog("[Haynoi] Pasteboard restored (was empty)")
            return
        }
        pb.clearContents()
        pb.writeObjects(items)
        NSLog("[Haynoi] Pasteboard restored (%d items)", items.count)
    }

    // MARK: - AX Helpers (Fix #2)

    /// Returns true if the target app has a focused element that is a text field
    /// (has a readable kAXValueAttribute). Returns true when AX is denied entirely
    /// (we can't tell, so we don't block Cmd+V).
    private static func hasFocusedTextElement(in app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        // AX denied or app doesn't expose elements — don't block.
        if err == .apiDisabled || err == .notImplemented { return true }
        guard err == .success else { return false }
        let focused = focusedRef as! AXUIElement
        var valueRef: CFTypeRef?
        // If we can read a value, it's a text-like element.
        return AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success
    }

    /// Reads the current AXValue string from the focused element of the given app.
    /// Returns nil if AX is unavailable or the element has no string value.
    private static func focusedElementValue(in app: NSRunningApplication?) -> String? {
        AXRead.focusedValue(in: app)
    }

    // MARK: - Keycode Resolution (Fix #8)

    /// Resolves the CGKeyCode for the character 'v' in the current keyboard layout.
    /// Result is cached; falls back to 0x09 if resolution fails.
    /// Resolve the keycode for 'v' on the current layout. TIS/TSM input-source
    /// APIs assert they run on the main thread (they SIGTRAP otherwise), but the
    /// paste path runs inside a background Task — so always hop to main.
    /// Call `prewarmKeyCode()` once at launch so the paste path hits the cache.
    static func resolveVKeyCode() -> CGKeyCode {
        if let cached = cachedVKeyCode { return cached }
        if Thread.isMainThread { return resolveVKeyCodeOnMain() }
        return DispatchQueue.main.sync { resolveVKeyCodeOnMain() }
    }

    /// Warm the keycode cache on the main thread (call from app launch).
    static func prewarmKeyCode() {
        if Thread.isMainThread { _ = resolveVKeyCodeOnMain() }
        else { DispatchQueue.main.async { _ = resolveVKeyCodeOnMain() } }
    }

    private static func resolveVKeyCodeOnMain() -> CGKeyCode {
        if let cached = cachedVKeyCode { return cached }

        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataRef = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return 0x09 // hardcoded fallback
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        let layoutPtr = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        // Scan all 128 keycodes for the one that produces 'v' (Unicode scalar 118) with no modifiers.
        let targetChar: UniChar = 118 // 'v'
        for keyCode in CGKeyCode(0)..<CGKeyCode(128) {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0, // no modifiers
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            if status == noErr, length == 1, chars[0] == targetChar {
                NSLog("[Haynoi] Resolved 'v' keyCode = 0x%02X", keyCode)
                cachedVKeyCode = keyCode
                return keyCode
            }
        }

        NSLog("[Haynoi] Could not resolve 'v' keyCode from layout, using 0x09")
        return 0x09
    }

    // MARK: - Fallback: Clipboard + Notification

    private static func copyToClipboardWithNotification(_ text: String, reason: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        notifyFallback(text, reason: reason)
    }

    /// Same notification without touching the clipboard — for the cases where the
    /// sentence is already there, or where the clipboard now belongs to the user.
    /// `banner` is the one-liner the app itself shows, so it never tells the user to
    /// press ⌘V when ⌘V would paste what they copied, not what they said.
    private static func notifyFallback(_ text: String, reason: String, banner: String = "⌘V to paste") {
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
            AppState.shared.error = banner
        }
    }
}
