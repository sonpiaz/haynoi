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

// MARK: - Learning master switch

/// Master kill-switch for correction CAPTURE — Signals A/B/C stop proposing new
/// learned entries when off (v2 Phase 5, redesign/10-DICTATION-LEARNING-V2.md).
/// USING the dictionary stays on: glossary biasing, the rewrite pass, and
/// existing replacement rules are unaffected. "Fix that" still replaces text —
/// only the learn-toast is silenced.
enum LearningSettings {
    static let key = "learningEnabled"

    /// Defaults to true when the key was never written — deliberately NOT a bare
    /// `bool(forKey:)`, which reads false before `register(defaults:)` runs (the
    /// muteMusic fresh-install bug, CHANGELOG [Unreleased]).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
    }
}

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
    // v1.1 — explicit "fix that" correction capture (Signal C).
    var confirmations: Int       // explicit "fix that" confirms; gates .learned .replacement activation (>= 2)
    var fireCount: Int           // times this .replacement actually fired (self-heal + §F effectiveness)
    // v2 scoreboard (§F) — times the user corrected AGAINST this rule after it
    // fired (the self-heal event). fireCount vs recorrectedCount is the
    // per-word accuracy ledger: "applied N× · M% kept".
    var recorrectedCount: Int

    /// Share of this rule's fires the user let stand, 0...1. nil until it has
    /// fired at least once — no evidence, no claim.
    var keptRate: Double? {
        guard fireCount > 0 else { return nil }
        return Double(max(0, fireCount - recorrectedCount)) / Double(fireCount)
    }

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
        createdAt: Date = Date(),
        confirmations: Int = 0,
        fireCount: Int = 0,
        recorrectedCount: Int = 0
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
        self.confirmations = confirmations
        self.fireCount = fireCount
        self.recorrectedCount = recorrectedCount
    }

    // Decode tolerantly — v1 `dictionary.json` files predate `confirmations`/
    // `fireCount`, so the synthesized decoder would throw `keyNotFound` on them.
    // Mirror Transcription's tolerant decode (AppState.swift): decodeIfPresent for
    // the new keys, defaulting to 0, and decode everything else normally.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        right = try c.decode(String.self, forKey: .right)
        wrong = try c.decodeIfPresent(String.self, forKey: .wrong)
        kind = try c.decode(Kind.self, forKey: .kind)
        source = try c.decode(Source.self, forKey: .source)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        caseSensitive = try c.decode(Bool.self, forKey: .caseSensitive)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        frequency = try c.decode(Int.self, forKey: .frequency)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        confirmations = try c.decodeIfPresent(Int.self, forKey: .confirmations) ?? 0
        fireCount = try c.decodeIfPresent(Int.self, forKey: .fireCount) ?? 0
        recorrectedCount = try c.decodeIfPresent(Int.self, forKey: .recorrectedCount) ?? 0
    }

    /// Activation predicate for a `.replacement` rule (§1.2): manual rules are
    /// always trusted; learned rules fire only once confirmed (>= 2). The explicit
    /// "fix that" path upserts with confirmations = 2, so it clears this gate
    /// immediately. Pure — single source of truth for `applyReplacementsTracked`'s
    /// filter and unit tests.
    var firesAsReplacement: Bool {
        guard enabled, kind == .replacement else { return false }
        return source == .manual || confirmations >= 2
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
    /// The file this store reads and writes. Internal so tests can prove they
    /// never point at the user's real dictionary.
    let fileURL: URL

    /// `fileURL` is injectable so tests round-trip a throwaway file; the app
    /// always goes through `shared`.
    init(fileURL: URL = PersonalDictionary.defaultFileURL()) {
        self.fileURL = fileURL
        self.entries = PersonalDictionary.load(from: fileURL)
        self.seenIDs = Set(self.entries.map(\.id))
        self.fileStamp = PersonalDictionary.stamp(of: fileURL)
        PersonalDictionary.clearUserImmutable(at: fileURL)
    }

    /// How the file looked when this store last read or wrote it. A different
    /// stamp means something else changed the file — a restore, a second build,
    /// or a hand edit — so its rows must not be written over.
    private struct FileStamp: Equatable {
        let modified: Date
        let size: Int
    }

    private var fileStamp: FileStamp?

    /// Every id this store has held, deleted ones included, so a merge brings
    /// back only rows it has never seen and a delete stays deleted.
    private var seenIDs: Set<UUID>

    /// Read through FileManager, not `URL.resourceValues`: Foundation caches
    /// resource values on the URL, so the same URL kept reporting the size and
    /// date from the first read and every later change looked like no change.
    private static func stamp(of url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int
        else { return nil }
        return FileStamp(modified: modified, size: size)
    }

    // MARK: Persistence

    /// Production Release only. Debug (`com.sonpiaz.haynoi.dev`) and tests
    /// must not share this folder — a Debug persist wiped the live file on
    /// 2026-09-17 (30 entries → empty at 18:29).
    static let productionFolderName = "Haynoi"
    static let developmentFolderName = "Haynoi-Dev"

    static func isRunningTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    static func supportFolderName(
        bundleIdentifier: String,
        isRunningTests: Bool
    ) -> String {
        if isRunningTests { return productionFolderName }
        if bundleIdentifier.hasSuffix(".dev") || bundleIdentifier.lowercased().contains("test") {
            return developmentFolderName
        }
        return productionFolderName
    }

    static func defaultFileURL(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.sonpiaz.haynoi",
        isRunningTests: Bool = PersonalDictionary.isRunningTests()
    ) -> URL {
        let fm = FileManager.default
        var base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        // A test run hosts the app, so `shared` would otherwise read and write
        // the user's real dictionary — which is how it got wiped on 2026-09-01.
        if isRunningTests {
            base = fm.temporaryDirectory
                .appendingPathComponent("HaynoiTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let dir = base.appendingPathComponent(
            supportFolderName(bundleIdentifier: bundleIdentifier, isRunningTests: isRunningTests),
            isDirectory: true
        )
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }

    static func isProductionDictionaryURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/Application Support/\(productionFolderName)/dictionary.json")
    }

    static func isProductionBundle(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""
    ) -> Bool {
        bundleIdentifier == "com.sonpiaz.haynoi"
    }

    /// The on-disk format lives in one place so the reader can't drift from the
    /// writer again: 0.3.6–0.3.10 wrote ISO-8601 dates but decoded them as
    /// numbers, so every launch silently started with an empty dictionary.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // human-auditable file
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func load(from url: URL) -> [DictionaryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try makeDecoder().decode([DictionaryEntry].self, from: data)
        } catch {
            // Never let the next persist() overwrite a file we couldn't read —
            // set it aside so the words in it stay recoverable.
            let aside = url.deletingLastPathComponent().appendingPathComponent(
                "dictionary.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                NSLog("[Haynoi] dictionary.json unreadable, moved to %@: %@",
                      aside.lastPathComponent, String(describing: error))
            } catch let moveError {
                NSLog("[Haynoi] dictionary.json unreadable and could NOT be set aside (%@) — the next save will overwrite it: %@",
                      String(describing: moveError), String(describing: error))
            }
            return []
        }
    }

    private func persist() {
        // Called on `queue`.
        if Self.isProductionDictionaryURL(fileURL), !Self.isProductionBundle() {
            NSLog("[Haynoi] refused to write the production dictionary from bundle %@",
                  Bundle.main.bundleIdentifier ?? "?")
            return
        }
        // The file changed under us: keep the rows it has and we never had.
        // 2026-09-17 a still-running app with an empty dictionary wrote over a
        // restore of 30 entries. A stamp is a guard, not a lock — two writes in
        // the same second with the same size still look unchanged.
        if let onDisk = Self.stamp(of: fileURL), onDisk != fileStamp {
            let theirs = Self.load(from: fileURL).filter { !seenIDs.contains($0.id) }
            if !theirs.isEmpty {
                entries.append(contentsOf: theirs)
                NSLog("[Haynoi] dictionary.json changed under us — kept %ld row(s) of it", theirs.count)
            }
        }
        seenIDs.formUnion(entries.map(\.id))
        if let data = try? Self.makeEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
            fileStamp = Self.stamp(of: fileURL)
        }
    }

    /// The restore lock (`uchg`) stops a still-running empty build from
    /// overwriting the file. The next production launch must be able to save.
    static func clearUserImmutable(at url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isUserImmutable = false
        try? mutable.setResourceValues(values)
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

    // MARK: - v1.1 learn / self-heal (Signal C)

    /// Upserts a `.learned` `.replacement` (the "Nhớ" handler target, §7.2). If a
    /// `.replacement` with the same (wrong, right) already exists, bumps its
    /// `confirmations` (capped at 2) and `frequency`; otherwise inserts a new
    /// `.learned` entry with the given `confirmations`. Dedupe reuses `add`'s
    /// case-insensitive (wrong, right) match, but on `.replacement` only, and
    /// must also carry `confirmations` — so the upsert is done directly here.
    @discardableResult
    func upsertLearnedReplacement(wrong: String, right: String, confirmations: Int, language: String? = nil) -> DictionaryEntry? {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty else { return nil }
        return queue.sync {
            if let idx = entries.firstIndex(where: {
                $0.kind == .replacement &&
                $0.right.caseInsensitiveCompare(r) == .orderedSame &&
                ($0.wrong ?? "").caseInsensitiveCompare(w) == .orderedSame
            }) {
                entries[idx].frequency += 1
                entries[idx].confirmations = min(entries[idx].confirmations + 1, 2)
                // Re-enable a previously self-healed rule the user is now reaffirming.
                entries[idx].enabled = true
                persist()
                return entries[idx]
            }
            let entry = DictionaryEntry(
                right: r, wrong: w, kind: .replacement, source: .learned,
                language: language, frequency: 0, confirmations: confirmations
            )
            entries.append(entry)
            persist()
            return entry
        }
    }

    /// Self-heal (§7.3): disable an enabled `.replacement` whose (wrong, right)
    /// match case-insensitively (NFC-normalized). Returns the disabled id, if any.
    @discardableResult
    func disableMatchingReplacement(wrong: String, right: String) -> UUID? {
        let w = wrong.precomposedStringWithCanonicalMapping
        let r = right.precomposedStringWithCanonicalMapping
        return queue.sync {
            guard let idx = entries.firstIndex(where: {
                $0.enabled && $0.kind == .replacement &&
                ($0.wrong ?? "").precomposedStringWithCanonicalMapping.caseInsensitiveCompare(w) == .orderedSame &&
                $0.right.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(r) == .orderedSame
            }) else { return nil }
            entries[idx].enabled = false
            // Scoreboard (§F): a reversal IS the evidence a fire was wrong.
            entries[idx].recorrectedCount += 1
            persist()
            return entries[idx].id
        }
    }

    /// Aggregate scoreboard across learned `.replacement` rules — total times
    /// they fired vs. times the user corrected back. Drives the Dictionary
    /// header's "applied N× · M% kept" and is the internal proof required
    /// before any "it learns you" marketing claim (v2 Phase 5 §F).
    var learnedScoreboard: (fires: Int, recorrections: Int) {
        queue.sync {
            entries
                .filter { $0.source == .learned && $0.kind == .replacement }
                .reduce((fires: 0, recorrections: 0)) {
                    ($0.fires + $1.fireCount, $0.recorrections + $1.recorrectedCount)
                }
        }
    }

    /// Lookup the enabled `.replacement` that would produce a given (wrong → right)
    /// span — used by self-heal to detect "user corrected back against a rule that
    /// just fired". Snapshot copy, safe off-queue.
    func enabledReplacement(matching wrong: String, right: String) -> DictionaryEntry? {
        let w = wrong.precomposedStringWithCanonicalMapping
        let r = right.precomposedStringWithCanonicalMapping
        return queue.sync {
            entries.first {
                $0.enabled && $0.kind == .replacement &&
                ($0.wrong ?? "").precomposedStringWithCanonicalMapping.caseInsensitiveCompare(w) == .orderedSame &&
                $0.right.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(r) == .orderedSame
            }
        }
    }

    /// Looks up entries by id (snapshot copy). Used by self-heal to resolve the
    /// rules recorded in `AppState.lastFiredRuleIDs`.
    func entries(withIDs ids: [UUID]) -> [DictionaryEntry] {
        guard !ids.isEmpty else { return [] }
        let set = Set(ids)
        return queue.sync { entries.filter { set.contains($0.id) } }
    }

    /// Bumps `fireCount` for the given rule ids and persists once. Fire-and-forget
    /// — never blocks transcription (§1.3).
    func incrementFireCounts(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        queue.sync {
            var changed = false
            for idx in entries.indices where set.contains(entries[idx].id) {
                entries[idx].fireCount += 1
                changed = true
            }
            if changed { persist() }
        }
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

    /// Number of auto-learned entries — the "Haynoi has learned N words" counter.
    var learnedCount: Int {
        queue.sync { entries.filter { $0.source == .learned }.count }
    }

    /// Whether there is any personal context to ground an LLM correction pass
    /// (Signal E gate) — an ungrounded fix-up pass over-corrects, so without
    /// this the pass must not run.
    var hasGroundingContext: Bool {
        !glossaryTerms().isEmpty || !correctionPairs(max: 1).isEmpty
    }

    /// Dictionary `right` forms that sound like `word` (v2 Phase 4) — named
    /// candidates for a low-confidence span, fed to the correction pass as a
    /// targeted hint. Sound-alike only; never applied as a replacement.
    func phoneticCandidates(for word: String, max limit: Int = 3) -> [String] {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for entry in enabledEntries(kinds: [.term, .replacement])
            .sorted(by: { $0.frequency > $1.frequency }) {
            let right = entry.right.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !right.isEmpty, seen.insert(right.lowercased()).inserted else { continue }
            if Phonetics.close(trimmed, right) {
                result.append(right)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// Pure filter behind `deleteAllLearned` — split out so the invariant
    /// (manual entries survive, learned entries go) is unit-testable without
    /// touching the real on-disk dictionary.
    static func removingLearned(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.filter { $0.source != .learned }
    }

    /// The Gboard-bar "delete what you've learned" control (v2 Phase 5): removes
    /// every `.learned` entry in one action; manual entries survive. Returns the
    /// number removed.
    @discardableResult
    func deleteAllLearned() -> Int {
        queue.sync {
            let before = entries.count
            entries = PersonalDictionary.removingLearned(entries)
            let removed = before - entries.count
            if removed > 0 { persist() }
            return removed
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

    /// Known (wrong → right) pairs for the LLM rewrite pass — grounded few-shot
    /// context (v2 Phase 1, redesign/10-DICTATION-LEARNING-V2.md). Trust bar is
    /// the SAME activation gate as the deterministic replace (`firesAsReplacement`)
    /// — no parallel gate, so an unconfirmed learned rule can't reach the LLM
    /// either. Frequency-ordered, capped: the dictionary is the retriever.
    func correctionPairs(max limit: Int = 10) -> [(wrong: String, right: String)] {
        enabledEntries(kinds: [.replacement])
            .filter { $0.firesAsReplacement }
            .sorted { $0.frequency > $1.frequency }
            .prefix(limit)
            .compactMap { entry in
                guard let w = entry.wrong?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !w.isEmpty else { return nil }
                let r = entry.right.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !r.isEmpty else { return nil }
                return (wrong: w, right: r)
            }
    }

    // MARK: - Deterministic replacement (Feedback path #2, §5.3)

    /// Applies enabled `.replacement` entries to `text`. Whole-word/phrase match
    /// on Unicode word boundaries (supports multi-syllable VI phrases like
    /// "Hà Nội" as one unit), NFC-normalized, never substring ("Cat"→"Dog" must
    /// not touch "Caterpillar"). Case-sensitive when the entry is caseSensitive.
    func applyReplacements(to text: String) -> String {
        applyReplacementsTracked(to: text).text
    }

    /// Like `applyReplacements`, but also reports which rules actually changed the
    /// text (v1.1 self-heal §7.3) and bumps each fired rule's `fireCount` (§F).
    /// The activation gate (§1.2): a `.learned` `.replacement` fires only once it
    /// has `confirmations >= 2`; `.manual` rules are always trusted. The explicit
    /// "fix that" learn path upserts with confirmations = 2, so it clears the gate
    /// immediately without threading an "explicit" flag through here.
    @discardableResult
    func applyReplacementsTracked(to text: String) -> (text: String, firedIDs: [UUID]) {
        let rules = enabledEntries(kinds: [.replacement]).filter { $0.firesAsReplacement }
        guard !rules.isEmpty else { return (text, []) }

        var result = text.precomposedStringWithCanonicalMapping  // NFC
        var firedIDs: [UUID] = []
        // Longer `wrong` first so multi-syllable phrases win over single tokens.
        for rule in rules.sorted(by: { ($0.wrong?.count ?? 0) > ($1.wrong?.count ?? 0) }) {
            guard let wrong = rule.wrong?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !wrong.isEmpty else { continue }
            let before = result
            result = PersonalDictionary.replaceWholeWord(
                in: result,
                wrong: wrong.precomposedStringWithCanonicalMapping,
                right: rule.right.precomposedStringWithCanonicalMapping,
                caseSensitive: rule.caseSensitive
            )
            if result != before { firedIDs.append(rule.id) }
        }
        // Fire-and-forget: bump fire counts off the transcription hot path.
        if !firedIDs.isEmpty { incrementFireCounts(ids: firedIDs) }
        return (result, firedIDs)
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
