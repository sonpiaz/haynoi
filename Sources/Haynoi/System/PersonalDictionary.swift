import Foundation

// MARK: - PersonalDictionary
//
// Typed, on-device personal dictionary that powers the "learn-from-corrections"
// loop (redesign/07-DICTATION-LEARNING.md §5). v1 SPINE only:
//   • typed DictionaryEntry stored as JSON at
//     ~/Library/Application Support/Haynoi/dictionary.json (100% local, no audio)
//   • one-shot idempotent migration from the legacy [String] UserDefaults store
//   • deterministic, diacritic-aware, whole-word post-transcription replace
//   • frequency-ordered bare-term glossary for prompt + Normal-mode rewrite
//
// NO auto-capture, NO re-dictation detector, NO server sync in v1 — those are
// v1.1+. CustomDictionary remains as a compat shim (bottom of this file) so the
// existing call sites keep compiling.

// MARK: - Model

/// A single dictionary row. `.term` biases recognition (soft); `.replacement`
/// is a hard, deterministic wrong→right swap applied locally after transcription.
struct DictionaryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var right: String            // canonical correct form ("Haynoi", "Sơn", "Hà Nội")
    var wrong: String?           // observed wrong form; nil = recognition-only term
    var kind: Kind               // .term (bias only) | .replacement (hard swap)
    var source: Source           // .manual | .learned
    var enabled: Bool            // per-entry kill-switch
    var caseSensitive: Bool      // default true for diacritic-bearing / mixed-case `right`
    var language: String?        // "vi" | "en" | nil
    var frequency: Int           // confirmations/uses → glossary priority
    var createdAt: Date

    enum Kind: String, Codable { case term, replacement }
    enum Source: String, Codable { case manual, learned }

    init(
        id: UUID = UUID(),
        right: String,
        wrong: String? = nil,
        kind: Kind = .term,
        source: Source = .manual,
        enabled: Bool = true,
        caseSensitive: Bool? = nil,
        language: String? = nil,
        frequency: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.right = right
        self.wrong = wrong
        self.kind = kind
        self.source = source
        self.enabled = enabled
        // Diacritic-bearing or mixed-case terms default to case-sensitive so the
        // `Sơn` (name) vs `sơn` ("paint") collision can't fire unintentionally.
        // The deterministic replace matches against `wrong`, so a diacritic on
        // EITHER side must force case-sensitivity (rule wrong="sơn" right="son"
        // would otherwise case-fold and clobber the name "Sơn").
        self.caseSensitive = caseSensitive ?? (
            DictionaryEntry.shouldBeCaseSensitive(right) ||
            (wrong.map(DictionaryEntry.shouldBeCaseSensitive) ?? false)
        )
        self.language = language
        self.frequency = frequency
        self.createdAt = createdAt
    }

    /// True when `text` contains combining diacritics or mixed-case letters —
    /// the cases where a case-insensitive match would be unsafe.
    static func shouldBeCaseSensitive(_ text: String) -> Bool {
        // Diacritics: NFD-decompose and look for combining marks.
        let decomposed = text.decomposedStringWithCanonicalMapping.unicodeScalars
        let hasDiacritic = decomposed.contains { $0.properties.canonicalCombiningClass != .notReordered }
        if hasDiacritic { return true }
        // Mixed case (e.g. "Haynoi", "iOS") — letters that aren't uniformly
        // all-lowercase or all-uppercase.
        let lettered = String(text.filter { $0.isLetter })
        guard !lettered.isEmpty else { return false }
        return lettered != lettered.lowercased() && lettered != lettered.uppercased()
    }
}

// MARK: - Store

/// Thread-safe-enough single-file store. All access goes through the shared
/// instance; reads/writes are serialized on an internal queue and cached in RAM.
final class PersonalDictionary {
    static let shared = PersonalDictionary()

    private let queue = DispatchQueue(label: "com.haynoi.personaldictionary")
    private var entries: [DictionaryEntry]
    private let fileURL: URL

    private init() {
        self.fileURL = PersonalDictionary.defaultFileURL()
        self.entries = PersonalDictionary.load(from: fileURL)
    }

    // MARK: Persistence

    private static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Haynoi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }

    private static func load(from url: URL) -> [DictionaryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DictionaryEntry].self, from: data)) ?? []
    }

    private func persist() {
        // Called on `queue`. Pretty-printed for human auditability of the file.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Read

    /// All entries (any state). Snapshot copy — safe to use off-queue.
    var all: [DictionaryEntry] {
        queue.sync { entries }
    }

    /// Enabled entries of the given kinds, newest-meaningful first by frequency.
    func enabledEntries(kinds: Set<DictionaryEntry.Kind>) -> [DictionaryEntry] {
        queue.sync {
            entries.filter { $0.enabled && kinds.contains($0.kind) }
        }
    }

    // MARK: Mutate

    /// Adds an entry, de-duplicating on (right, wrong, kind). On a duplicate,
    /// bumps frequency instead of inserting. Returns the resulting entry.
    ///
    /// `caseSensitiveDedupe` (used only by the one-shot legacy migration)
    /// compares `right`/`wrong` exactly, so case-distinct legacy words like
    /// "Son" and "son" both survive rather than collapsing into one.
    @discardableResult
    func add(_ entry: DictionaryEntry, caseSensitiveDedupe: Bool = false) -> DictionaryEntry {
        queue.sync {
            if let idx = entries.firstIndex(where: {
                guard $0.kind == entry.kind else { return false }
                if caseSensitiveDedupe {
                    return $0.right == entry.right && ($0.wrong ?? "") == (entry.wrong ?? "")
                }
                return $0.right.caseInsensitiveCompare(entry.right) == .orderedSame &&
                    ($0.wrong ?? "").caseInsensitiveCompare(entry.wrong ?? "") == .orderedSame
            }) {
                entries[idx].frequency += 1
                persist()
                return entries[idx]
            }
            entries.append(entry)
            persist()
            return entry
        }
    }

    /// Convenience for a plain recognition term ("Son", "Affitor").
    @discardableResult
    func addTerm(_ right: String, source: DictionaryEntry.Source = .manual, language: String? = nil) -> DictionaryEntry? {
        let trimmed = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return add(DictionaryEntry(right: trimmed, kind: .term, source: source, language: language))
    }

    /// Convenience for a manual wrong→right replacement.
    @discardableResult
    func addReplacement(wrong: String, right: String, source: DictionaryEntry.Source = .manual, language: String? = nil) -> DictionaryEntry? {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return nil }
        return add(DictionaryEntry(right: r, wrong: w, kind: .replacement, source: source, language: language))
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        queue.sync {
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[idx].enabled = enabled
            persist()
        }
    }

    func delete(id: UUID) {
        queue.sync {
            entries.removeAll { $0.id == id }
            persist()
        }
    }

    // MARK: - Glossary (prompt + rewrite context)

    /// Bare, frequency-ordered, de-duplicated list of `right` forms from enabled
    /// .term + .replacement entries — the soft-bias glossary. Conservatively
    /// capped to keep well under whisper's 224-token prompt window (a real
    /// tokenizer is a v1.2 refinement; this char budget is the safe interim cap).
    func glossaryTerms(maxChars: Int = 600) -> [String] {
        let kinds: Set<DictionaryEntry.Kind> = [.term, .replacement]
        let ordered = enabledEntries(kinds: kinds)
            .sorted { $0.frequency > $1.frequency }

        var seen = Set<String>()
        var result: [String] = []
        var used = 0
        for e in ordered {
            let term = e.right.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            if seen.contains(key) { continue }
            // +2 ≈ ", " separator cost.
            if used + term.count + 2 > maxChars { break }
            seen.insert(key)
            result.append(term)
            used += term.count + 2
        }
        return result
    }

    // MARK: - Deterministic replacement (Feedback path #2, §5.3)

    /// Applies enabled `.replacement` entries to `text`. Whole-word/phrase match
    /// on Unicode word boundaries (supports multi-syllable VI phrases like
    /// "Hà Nội" as one unit), NFC-normalized, never substring ("Cat"→"Dog" must
    /// not touch "Caterpillar"). Case-sensitive when the entry is caseSensitive.
    func applyReplacements(to text: String) -> String {
        let rules = enabledEntries(kinds: [.replacement])
        guard !rules.isEmpty else { return text }

        var result = text.precomposedStringWithCanonicalMapping  // NFC
        // Longer `wrong` first so multi-syllable phrases win over single tokens.
        for rule in rules.sorted(by: { ($0.wrong?.count ?? 0) > ($1.wrong?.count ?? 0) }) {
            guard let wrong = rule.wrong?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !wrong.isEmpty else { continue }
            result = PersonalDictionary.replaceWholeWord(
                in: result,
                wrong: wrong.precomposedStringWithCanonicalMapping,
                right: rule.right.precomposedStringWithCanonicalMapping,
                caseSensitive: rule.caseSensitive
            )
        }
        return result
    }

    /// Whole-word/phrase replacement using NSRegularExpression word boundaries.
    /// `\b` keys off Unicode word characters, so a phrase is matched as a unit
    /// and never inside a longer word.
    static func replaceWholeWord(in text: String, wrong: String, right: String, caseSensitive: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: wrong)
        let pattern = "\\b\(escaped)\\b"
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let template = NSRegularExpression.escapedTemplate(for: right)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    // MARK: - Migration (one-shot, idempotent — §5.1)

    private static let migratedFlag = "dictionaryMigratedV1"
    private static let legacyKey = "customDictionary"

    /// Converts the legacy `[String]` UserDefaults dictionary into typed
    /// `.term`/`.manual` entries exactly once. The legacy key is left readable
    /// for rollback. Re-running is a no-op (guarded by `dictionaryMigratedV1`).
    func migrateLegacyIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.migratedFlag) else { return }
        let legacy = defaults.stringArray(forKey: Self.legacyKey) ?? []
        for word in legacy {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Exact-match dedup: legacy words were already de-duped by the old
            // add(), so case-distinct entries ("Son"/"son") must both survive.
            _ = add(DictionaryEntry(right: trimmed, kind: .term, source: .manual), caseSensitiveDedupe: true)
        }
        // Set the flag even when the legacy list was empty — migration ran.
        defaults.set(true, forKey: Self.migratedFlag)
    }

    // MARK: - Cold-start seed (§5 review E)

    private static let seededFlag = "dictionarySeededV1"

    /// Seeds the dictionary from the user's display name (Google profile) on
    /// first run after this version, so a fresh user isn't empty. Idempotent
    /// (guarded by `dictionarySeededV1`) and a safe no-op when no name exists.
    func seedFromDisplayNameIfNeeded(displayName: String?, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.seededFlag) else { return }
        // Only flip the flag once we actually have a name to seed from. The
        // common first-run path is launch → THEN sign-in, so the name is nil at
        // launch; leaving the flag false lets a later launch (or the sign-in
        // success path) seed once the display name becomes available.
        guard let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        // Split into word tokens; skip trivial single-character tokens.
        let tokens = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for token in tokens where token.count >= 2 {
            _ = addTerm(token, source: .manual)
        }
        defaults.set(true, forKey: Self.seededFlag)
    }
}

// MARK: - CustomDictionary compat shim
//
// Existing call sites (STTProvider, etc.) keep using CustomDictionary. It now
// routes through PersonalDictionary instead of the flat UserDefaults array.
// `words` returns the `right` of enabled, non-deleted .term + .replacement
// entries; promptFragment keeps its original shape.

enum CustomDictionary {
    /// Right-side forms of enabled term + replacement entries (never `wrong`).
    static var words: [String] {
        PersonalDictionary.shared.glossaryTerms()
    }

    /// Unchanged shape: "Custom vocabulary: Son, Mandeck, Hidrix, Affitor. "
    static var promptFragment: String {
        let w = words.filter { !$0.isEmpty }
        guard !w.isEmpty else { return "" }
        return "Custom vocabulary: \(w.joined(separator: ", ")). "
    }

    /// Routes into PersonalDictionary as a manual .term.
    static func add(_ word: String) {
        _ = PersonalDictionary.shared.addTerm(word, source: .manual)
    }

    /// Removes the entry whose `right` matches the word at `index` in `words`.
    /// Kept for source compatibility; the new Settings UI deletes by id.
    static func remove(at index: Int) {
        let current = words
        guard index < current.count else { return }
        let target = current[index]
        if let entry = PersonalDictionary.shared.all.first(where: {
            $0.right.caseInsensitiveCompare(target) == .orderedSame
        }) {
            PersonalDictionary.shared.delete(id: entry.id)
        }
    }
}
