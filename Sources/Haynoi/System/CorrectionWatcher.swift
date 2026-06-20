import AppKit

// MARK: - CorrectionWatcher (v1.3 — Signal A: AX read-back of in-place edits)
//
// The HARDEST learning signal: after a successful dictation insertion, the user
// goes back INSIDE the destination app and retypes the wrong word in place
// (e.g. "Hai Noi" → "Haynoi"). We detect that edit by re-reading the AX value of
// the element we wrote into, locating ONLY our inserted span, diffing it against
// what we inserted, and — if the change looks like a proper-noun near-homophone
// fix — proposing wrong → right via the same v1.1 toast. High-confidence (the user
// edited OUR output) → upsertLearnedReplacement(confirmations: 2) so it activates
// immediately, exactly like "fix that".
//
// NON-NEGOTIABLE: SUGGEST-NEVER-SILENT, LOCAL-ONLY. We read ONLY our inserted span,
// NEVER the whole field or surrounding text, NEVER secure/password fields. The
// anchor lives in RAM and is discarded after one re-read. When in doubt: BAIL.
//
// Reuses (does NOT reinvent): TextInserter.AXRead.* (the single AX reader),
// CorrectionDiff.extractChange, CorrectionDetector.qualifiesAsLearnable,
// PersonalDictionary.upsertLearnedReplacement, LiveContext.isActive,
// FloatingBarController.showLearnToast.
@MainActor
final class CorrectionWatcher {
    static let shared = CorrectionWatcher()

    /// Settings kill-switch. Default ON (registered in HaynoiApp). When false,
    /// every public entry is a no-op.
    private static let enabledKey = "signalAEnabled"

    /// Debounce window before re-reading the anchored element (§ trigger choice:
    /// 8–15s). Long enough that the user has finished their edit, short enough the
    /// field hasn't been navigated away.
    private static let debounceSeconds: TimeInterval = 10

    /// Apps whose focused NSText elements return a reliable, readable kAXValue and a
    /// stable kAXSelectedTextRange. ARM Signal A ONLY here. Chrome/Chromium, Electron
    /// (Slack/VSCode/Discord), and terminals return unreliable/empty AX → never arm.
    /// If the running app is not in this set (and not allowed by the generic
    /// fallback in `isAXCooperative`), do not arm (fail closed).
    static let axCooperativeApps: Set<String> = [
        "com.apple.TextEdit",
        "com.apple.Notes",
        "com.apple.iWork.Pages",
        "com.apple.mail",
        "com.apple.Stickies",   // native NSText, safe
        "com.apple.dt.Xcode",   // source editor is native NSText (conservative)
    ]

    /// Hard denylist for the generic fallback: apps that return unreliable AX even
    /// though they expose elements. Electron / Chromium / terminals.
    static let axDenylist: Set<String> = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]

    /// Reason a re-read fired (debug only — never logs content).
    enum ReReadReason: String {
        case debounce
        case nextDictation
        case deactivate
    }

    /// The single current anchor — replaced on each new insertion, consumed once on
    /// re-read. Holds NO document text, only what we inserted + where + identity.
    private var anchor: InsertionAnchor?
    private var debounceTimer: Timer?
    /// One shared app-deactivate observer (NOT a per-element AXObserver). Optional
    /// bonus trigger; torn down in `disarm`.
    private var deactivateObserver: NSObjectProtocol?

    private init() {}

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Whitelist

    /// True when `bundleID` is an AX-cooperative app we may arm in. Explicit
    /// whitelist OR generic native fallback (not denylisted). The deeper role check
    /// (AXTextField/AXTextArea, not AXWebArea) happens at re-read time via the §5
    /// content guard; arming only needs the bundle-id gate plus the natural
    /// `span != nil` gate the caller already applies.
    static func isAXCooperative(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if axCooperativeApps.contains(bundleID) { return true }
        if axDenylist.contains(bundleID) { return false }
        // Generic fallback: a native-looking app we didn't enumerate. Be
        // conservative — reject anything that smells like Electron/Chromium.
        let lower = bundleID.lowercased()
        if lower.contains("electron") || lower.contains("chrom") { return false }
        // Allow other Apple-native apps (com.apple.*) that returned a span; block
        // everything else by default (fail closed). The caller's span != nil gate
        // already proves AX gave a real, readable location for this insertion.
        return bundleID.hasPrefix("com.apple.")
    }

    // MARK: - Arm

    /// Record the current InsertionAnchor (replaces any prior — we only track the
    /// most recent insertion) and start the debounce. No-op + clear if Signal A is
    /// disabled or the app is not AX-cooperative.
    func arm(anchor newAnchor: InsertionAnchor) {
        guard isEnabled else { disarm(); return }
        guard Self.isAXCooperative(newAnchor.bundleID) else {
            // Not an app we can safely read back — never arm here.
            disarm()
            return
        }
        // Replace any prior anchor (we only ever observe the latest insertion).
        disarm()
        // Capture a cheap, stable identity of the field RIGHT AFTER insert: the
        // UTF-16 length of its whole AXValue. Used at re-read to detect a prefix
        // shift (text inserted/deleted BEFORE our span moves our content out of the
        // recorded offsets) or a switch to a wholly different field. We store the
        // REAL field value length here — not the inserted-text length the caller
        // passed in — overwriting the caller's placeholder. nil = couldn't read →
        // re-read will simply skip the length check (the span-bounds + near-edit
        // guards still apply).
        var armed = newAnchor
        if let app = NSRunningApplication(processIdentifier: newAnchor.pid),
           let value = TextInserter.AXRead.focusedValue(in: app) {
            armed.valueLengthAtInsert = value.utf16.count
        } else {
            armed.valueLengthAtInsert = nil
        }
        anchor = armed

        debounceTimer = Timer.scheduledTimer(withTimeInterval: Self.debounceSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reRead(reason: .debounce) }
        }

        // Optional bonus trigger: one shared app-deactivate observer. When the
        // anchored app deactivates (user clicks away), flush early. Single token,
        // removed in disarm — NEVER a per-element AXObserver.
        deactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, let a = self.anchor else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.processIdentifier == a.pid {
                    self.reRead(reason: .deactivate)
                }
            }
        }
    }

    // MARK: - Re-read (the core)

    /// Re-fetch the focused value of the anchored app, run the stale-anchor safety
    /// guard, extract ONLY our inserted span, diff + gate, and on a qualifying
    /// candidate propose wrong → right. ALWAYS disarms after one attempt (one shot
    /// per insertion, success or bail) — never re-reads twice.
    func reRead(reason: ReReadReason) {
        guard isEnabled else { disarm(); return }
        guard let a = anchor else { return }
        // One shot: consume the anchor immediately so a second trigger is a no-op.
        disarm()

        // (1) App identity: the running app for the pid still exists and matches.
        // pid reuse → bail.
        guard let app = NSRunningApplication(processIdentifier: a.pid),
              app.bundleIdentifier == a.bundleID else {
            return
        }

        // (2) Whitelist still holds.
        guard Self.isAXCooperative(a.bundleID) else { return }

        // (3) Secure field: bail BEFORE reading any value (password field, privacy
        // non-negotiable).
        if TextInserter.AXRead.isFocusedSecure(in: app) { return }

        // (3b) Role gate: only AXTextField / AXTextArea. AXWebArea (browser) → bail.
        guard let roleValue = TextInserter.AXRead.focusedRoleAndValue(in: app) else { return }
        if let role = roleValue.role {
            let ok = role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String)
            guard ok else { return }
        }

        // (4) Readable value.
        guard let current = roleValue.value ?? TextInserter.AXRead.focusedValue(in: app) else { return }
        let v = Array(current.utf16)

        // (4b) Prefix-shift / identity guard. We recorded the field's value length
        // right after insert. The ONLY change we can attribute to "the user edited
        // OUR word in place" is one confined to the span — i.e. the total value
        // length may change by at most the span's own length (full delete) up to
        // a small in-place re-type. If the field grew/shrank by MORE than the span
        // could account for, text was inserted/deleted OUTSIDE our span (most
        // dangerously BEFORE it, which silently slides our content off the recorded
        // offsets) — or focus moved to a different field entirely. Either way the
        // recorded offsets no longer point at our content: BAIL. We allow a small
        // slack so a legitimate same-length-ish in-place fix still passes. (Skipped
        // when we couldn't capture the length at arm time.)
        if let lenAtInsert = a.valueLengthAtInsert {
            let delta = abs(v.count - lenAtInsert)
            // A real in-place edit of our span changes length by at most ~the span
            // length (delete) plus a little growth headroom.
            let allowed = a.span.length + 8
            guard delta <= allowed else { return }
        }

        // (5) Bounds: span must lie within the current value. Field shrank / wrong
        // field / scrolled re-render → out of bounds → bail. (Same shape as
        // TextInserter.replaceSpan's guard.)
        let loc = a.span.location
        let len = a.span.length
        guard loc != NSNotFound, loc >= 0, len >= 0, loc + len <= v.count else { return }

        // (6) Extract ONLY our span — NEVER the surrounding text.
        let spanText = String(decoding: v[loc..<(loc + len)], as: UTF16.self)
        let spanNFC = spanText.precomposedStringWithCanonicalMapping
        let insertedNFC = a.inserted.precomposedStringWithCanonicalMapping

        // Unchanged → the user didn't edit our word → nothing to learn.
        if spanNFC == insertedNFC { return }

        // Wrong-field signature: the span content is a wholly unrelated string at
        // those offsets. Require it to still be a localized near-edit of T — share a
        // common prefix OR suffix character region with what we inserted. We never
        // read anything OUTSIDE the span to make this call.
        guard sharesEdge(spanNFC, insertedNFC) else { return }

        // (7) Diff + gate (reuse CorrectionDiff + the shared CorrectionDetector gate).
        // Direction: wrong = T (what we inserted), right = spanText (what the user
        // typed in place — ground truth).
        guard let change = CorrectionDiff.extractChange(from: a.inserted, to: spanText) else { return }
        guard CorrectionDetector.qualifiesAsLearnable(wrong: change.wrong, right: change.right) else { return }

        propose(wrong: change.wrong, right: change.right)
    }

    /// True when `a` (the span we read back) is a genuine localized near-edit of `b`
    /// (what we inserted) — NOT a stranger that merely happens to share one edge
    /// character at the same offsets. A single shared first/last char is far too weak
    /// to prove the focused field is still ours (a different field's "...Saigon..."
    /// shares S/n with "Sonpiaz"); we instead require a real edit-distance bound,
    /// proportional to the word length, so only an actual in-place re-type of our
    /// word qualifies. Operates purely on the two span strings — no surrounding
    /// context is ever read.
    private func sharesEdge(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased()
        let y = b.lowercased()
        if x == y { return true }
        // Allowed edits scale with the inserted word length: ~⌈len/3⌉, clamped to
        // [1, 4]. A homophone fix ("Hai Noi" → "Haynoi") stays well within; an
        // unrelated string at the same offsets does not.
        let maxLen = max(x.count, y.count)
        let bound = min(4, max(1, (maxLen + 2) / 3))
        return Self.levenshteinWithin(x, y, bound: bound)
    }

    /// Bounded Levenshtein: true iff edit distance between `a` and `b` is <= `bound`.
    /// Early-exits once every cell in a row exceeds `bound` (cheap for short strings).
    private static func levenshteinWithin(_ a: String, _ b: String, bound: Int) -> Bool {
        let s = Array(a)
        let t = Array(b)
        if abs(s.count - t.count) > bound { return false }
        var prev = Array(0...t.count)
        for i in 1...max(s.count, 1) where !s.isEmpty {
            var curr = [Int](repeating: 0, count: t.count + 1)
            curr[0] = i
            var rowMin = curr[0]
            if !t.isEmpty {
                for j in 1...t.count {
                    let cost = s[i - 1] == t[j - 1] ? 0 : 1
                    curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                    rowMin = min(rowMin, curr[j])
                }
            }
            if rowMin > bound { return false }
            prev = curr
        }
        return prev[t.count] <= bound
    }

    // MARK: - Propose

    /// Surface the v1.1 learn toast (suppressed in live/recording contexts). On
    /// "Nhớ" → upsertLearnedReplacement(confirmations: 2), identical to fix-that.
    private func propose(wrong: String, right: String) {
        guard !LiveContext.isActive() else { return }
        FloatingBarController.shared.showLearnToast(
            wrong: wrong, right: right,
            onRemember: {
                _ = PersonalDictionary.shared.upsertLearnedReplacement(
                    wrong: wrong, right: right, confirmations: 2)
                NSLog("[Haynoi] Learned (Signal A, AX read-back): %@ → %@", wrong, right)
                // Metadata only: just which detector fired — never the term strings.
                Analytics.capture("dictionary_term_learned", ["signal": "ax_edit"])
            },
            onIgnore: {}
        )
    }

    // MARK: - Disarm (privacy / no-leak)

    /// Clear the anchor, invalidate the debounce timer, and remove the shared
    /// app-deactivate observer. Called on app teardown and after every re-read.
    func disarm() {
        anchor = nil
        debounceTimer?.invalidate()
        debounceTimer = nil
        if let token = deactivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            deactivateObserver = nil
        }
    }
}

// MARK: - InsertionAnchor

/// Everything Signal A needs to re-find OUR inserted span later and verify it's
/// still ours — and NOTHING about the user's surrounding document. A value type,
/// recorded at insert, consumed once on re-read. RAM-only; never persisted.
///
/// We deliberately do NOT cache a raw AXUIElement across time (refs go stale on
/// re-render/scroll). We re-fetch the currently focused element at re-read time and
/// verify it's ours by span-content match, exactly like TextInserter.replaceSpan.
struct InsertionAnchor {
    let bundleID: String          // target app identity (whitelist check)
    let pid: pid_t                // re-find the AX app element at re-read time
    let inserted: String          // T — exactly what TextInserter inserted (NFC at compare)
    let span: NSRange             // UTF-16 (location,length) of T at insert time
    // UTF-16 length of the whole field VALUE right after insert (identity / prefix-
    // shift guard). Callers pass nil; CorrectionWatcher.arm overwrites it with the
    // real AXValue length it reads at arm time. nil when that read failed → re-read
    // skips the length check (other guards still apply).
    var valueLengthAtInsert: Int?
    let at: Date                  // for the debounce / staleness window
}
