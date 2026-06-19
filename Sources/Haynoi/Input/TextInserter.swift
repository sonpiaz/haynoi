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
        if let target = targetApp {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != target.processIdentifier {
                NSLog("[Haynoi] ⚠️ Frontmost mismatch after settle (%@ vs %@) — clipboard fallback",
                      frontmost?.bundleIdentifier ?? "?",
                      target.bundleIdentifier ?? "?")
                copyToClipboardWithNotification(text, reason: "Press ⌘V to paste.")
                return InsertionResult(inserted: text, span: nil, targetApp: targetApp)
            }
        }

        // Step 2: Clipboard + Cmd+V — PRIMARY method (like Wispr Flow)
        // AX insertion "succeeds" on Electron apps (Mandeck, VS Code, Slack, etc.)
        // but text is silently ignored. Cmd+V is the only reliable universal method.
        if axTrusted {
            // Snapshot the caret position BEFORE paste so we can derive the span
            // it occupied (caret-after − text length) for an in-place "fix that".
            let preCaret = focusedSelectionRange(in: targetApp ?? NSWorkspace.shared.frontmostApplication)
            let pasted = await pasteViaClipboard(text, targetApp: targetApp)
            if pasted {
                NSLog("[Haynoi] Insert via Cmd+V")
                let span = pasteSpan(preCaret: preCaret, text: text, targetApp: targetApp)
                return InsertionResult(inserted: text, span: span, targetApp: targetApp)
            }
        }

        // Step 3: AX insertion fallback (works for native macOS apps)
        if axTrusted {
            let axSpan = tryAXInsertionReturningSpan(text, targetApp: targetApp)
            if let span = axSpan {
                NSLog("[Haynoi] Insert via AX")
                // span may be NSRange(location: NSNotFound, ...) when AX inserted
                // but the location was unknown (selectedText path). Normalize.
                let usable = span.location == NSNotFound ? nil : span
                return InsertionResult(inserted: text, span: usable, targetApp: targetApp)
            }
        }

        // Step 4: Fallback — put in clipboard and notify
        NSLog("[Haynoi] All insert methods failed, clipboard fallback")
        copyToClipboardWithNotification(text,
            reason: axTrusted
                ? "Auto-paste failed. Press ⌘V to paste."
                : "Grant Accessibility in System Settings."
        )
        return InsertionResult(inserted: text, span: nil, targetApp: targetApp)
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

    @discardableResult
    private static func tryAXInsertion(_ text: String, targetApp: NSRunningApplication?) -> Bool {
        tryAXInsertionReturningSpan(text, targetApp: targetApp) != nil
    }

    /// AX direct insert. Returns the UTF-16 span the inserted text now occupies,
    /// or nil if all AX paths failed. When the selectedText path succeeds but the
    /// pre-insert caret was unknown, the returned span has `location == NSNotFound`
    /// (length set), signalling "inserted, location unknown" to the caller.
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
        guard let app else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            return nil
        }
        let focused = focusedRef as! AXUIElement
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return range
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
    static func replaceSpan(_ span: NSRange?, with newText: String, oldText: String, targetApp: NSRunningApplication?) async -> Bool {
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
            _ = await insert(newText, targetApp: targetApp)
            return false
        }

        guard let app = targetApp ?? NSWorkspace.shared.frontmostApplication else {
            _ = await insert(newText, targetApp: targetApp)
            return false
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            _ = await insert(newText, targetApp: targetApp)
            return false
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
            _ = await insert(newText, targetApp: targetApp)
            return false
        }
        let valueUTF16 = Array(currentValue.utf16)
        guard span.length >= 0,
              span.location >= 0,
              span.location + span.length <= valueUTF16.count else {
            // Span points past the end of the current value (field changed / shrank
            // / wrong element). Bail to insert-at-cursor.
            NSLog("[Haynoi] replaceSpan: span out of bounds (loc=%d len=%d count=%d) — inserting at cursor",
                  span.location, span.length, valueUTF16.count)
            _ = await insert(newText, targetApp: targetApp)
            return false
        }
        let spanText = String(decoding: valueUTF16[span.location..<(span.location + span.length)], as: UTF16.self)
        guard spanText.precomposedStringWithCanonicalMapping
                == oldText.precomposedStringWithCanonicalMapping else {
            // The text under the span is no longer the user's old text — replacing
            // would destroy whatever now occupies those offsets. Insert at cursor.
            NSLog("[Haynoi] replaceSpan: span no longer matches oldText — inserting at cursor")
            _ = await insert(newText, targetApp: targetApp)
            return false
        }

        // Set the selection to the old span.
        var cfSpan = CFRangeMake(span.location, span.length)
        guard let axSpan = AXValueCreate(.cfRange, &cfSpan) else {
            _ = await insert(newText, targetApp: targetApp)
            return false
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
            let pasted = await pasteViaClipboard(newText, targetApp: targetApp)
            if pasted {
                NSLog("[Haynoi] replaceSpan: paste-over-selection OK")
                return true
            }
        }

        // Could not replace in place — insert at cursor (old text remains).
        NSLog("[Haynoi] replaceSpan: all in-place paths failed — inserting at cursor")
        _ = await insert(newText, targetApp: targetApp)
        return false
    }

    // MARK: - Clipboard + Cmd+V (Fix #2, #3, #8)

    private static func pasteViaClipboard(_ text: String, targetApp: NSRunningApplication?) async -> Bool {
        let pb = NSPasteboard.general

        // Fix #2: check for a focused text element before investing in a paste.
        // If AX reports no settable/readable text element, skip Cmd+V and fall through.
        if let app = targetApp ?? NSWorkspace.shared.frontmostApplication {
            let hasFocusedText = hasFocusedTextElement(in: app)
            if !hasFocusedText {
                // AX was denied entirely — proceed anyway (best available, per spec).
                // Only skip if AX explicitly reports no text field.
                NSLog("[Haynoi] AX: no focused text element in %@, proceeding with Cmd+V",
                      app.bundleIdentifier ?? "?")
            }
        }

        // Fix #3: snapshot existing pasteboard contents before we overwrite.
        let savedItems = snapshotPasteboard(pb)
        let preWriteChangeCount = pb.changeCount

        // Write our text, concealed from clipboard managers.
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Fix #3: ConcealedType tells clipboard managers (Alfred, Paste, etc.) to skip this entry.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.writeObjects([item])
        let postWriteChangeCount = pb.changeCount

        NSLog("[Haynoi] Pasteboard written (changeCount %d→%d)", preWriteChangeCount, postWriteChangeCount)

        // Small delay to let pasteboard sync.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Fix #2: snapshot value of focused element BEFORE paste for change detection.
        let preValue = focusedElementValue(in: targetApp ?? NSWorkspace.shared.frontmostApplication)

        // Fix #8: resolve 'v' keycode from current keyboard layout at runtime.
        let vKeyCode = resolveVKeyCode()

        // Simulate Cmd+V.
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            NSLog("[Haynoi] CGEventSource failed")
            restorePasteboard(pb, items: savedItems, writtenChangeCount: postWriteChangeCount)
            return false
        }

        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false) else {
            NSLog("[Haynoi] CGEvent creation failed")
            restorePasteboard(pb, items: savedItems, writtenChangeCount: postWriteChangeCount)
            return false
        }

        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)

        // Small gap between key down and up.
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)

        NSLog("[Haynoi] Cmd+V posted (keyCode=0x%02X)", vKeyCode)

        // Fix #2: wait ~300ms then check whether the focused element's value changed.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        let postValue = focusedElementValue(in: targetApp ?? NSWorkspace.shared.frontmostApplication)
        let pasteDetected: Bool
        if let pre = preValue, let post = postValue {
            // Paste landed if value changed, OR if text was inserted (post contains pre's text plus ours).
            pasteDetected = post != pre
        } else {
            // Can't read AX value (AX denied) — assume paste worked (best available).
            pasteDetected = true
        }

        // Fix #3: restore old clipboard ~400ms after paste, unless someone else wrote.
        // 400ms total = 300ms we waited + 100ms additional here.
        // All pasteboard access is confined to @MainActor, eliminating Sendable warnings.
        let restoreChangeCount = postWriteChangeCount
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms more = ~400ms total
            restorePasteboard(NSPasteboard.general, items: savedItems, writtenChangeCount: restoreChangeCount)
        }

        if pasteDetected {
            return true
        }

        // Fix #2: value unchanged — fall through to AX insertion.
        NSLog("[Haynoi] Cmd+V: value unchanged after 300ms, falling through to AX")
        return false
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
    private static func restorePasteboard(_ pb: NSPasteboard, items: [NSPasteboardItem], writtenChangeCount: Int) {
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
        guard let app else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
            return nil
        }
        let focused = focusedRef as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
              let str = valueRef as? String else { return nil }
        return str
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
