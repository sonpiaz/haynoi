import Foundation

// MARK: - CorrectionDetector (v1.2 — Signal B: re-dictation similarity)
//
// Low-confidence, opportunistic learning source (redesign/07-DICTATION-LEARNING.md
// §3 Signal B, §5.4). When the user re-dictates a near-identical phrase — because
// the first try was misheard — the divergent token is a *candidate* learnable term.
//
// Confidence is LOW (no ground truth: T2 is as likely to be wrong as T1, and
// directionality is only *assumed*), so a qualifying detection may ONLY ever
// SUGGEST a `.term` (glossary soft-bias) — NEVER a `.replacement` (hard swap). A
// wrong `.term` suggestion is harmless because a soft bias can't corrupt output.
//
// State is RAM-only: the last 1–2 (transcript, timestamp) live here and are never
// written to disk. Nothing about Signal B is persisted except the `.term` the user
// explicitly taps "Nhớ" on (which goes through PersonalDictionary like any other).
@MainActor
final class CorrectionDetector {
    static let shared = CorrectionDetector()

    /// One observed transcript + when it was produced. RAM-only, never persisted.
    private struct Recent {
        let text: String
        let at: Date
    }

    /// Most-recent-first ring of the last few transcripts. We only ever compare T2
    /// to the single most recent prior transcript (T1), but keep a tiny buffer so a
    /// future window tweak has the history. Capped at 2 — never grows.
    private var recents: [Recent] = []
    private let maxRecents = 2

    /// Re-dictation window (§5.4: ~15s, NOT the 60s "fix that" window).
    private let window: TimeInterval = 15

    /// Whole-string floor: loose, only to reject two unrelated sentences. The REAL
    /// near-homophone test is the per-changed-token gate below (similarity + edit
    /// distance on the diff span), so a short re-dictation of just the misheard
    /// word ("Hai Noi" → "Hà Nội") is no longer drowned out by sentence length.
    private let minSimilarity = 0.5

    /// Max Levenshtein distance on the single changed token. True corrections are
    /// near-homophones ("Hai Noi" / "Haynoi"), not different words.
    private let maxTokenEditDistance = 4

    private init() {}

    /// A qualifying re-dictation suggestion: the candidate correct term to learn as
    /// a soft-bias `.term`. `wrong` is kept only for logging/diff symmetry.
    struct Suggestion {
        let wrong: String
        let right: String
    }

    // MARK: - Public hook

    /// Records a freshly-produced transcript and, if it qualifies as a re-dictation
    /// correction of the most recent prior transcript, returns the soft-bias term to
    /// suggest. Returns nil otherwise. Always records `text` for the next round.
    ///
    /// SUGGEST-NEVER-SILENT: the caller must still show the toast and only add the
    /// `.term` when the user taps "Nhớ". This never mutates the dictionary.
    @discardableResult
    func observe(_ text: String, at now: Date = Date()) -> Suggestion? {
        let t2 = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { record(t2, at: now) }
        guard !t2.isEmpty else { return nil }

        // Compare to the single most recent prior transcript within the window.
        guard let prior = recents.first, now.timeIntervalSince(prior.at) <= window else {
            return nil
        }
        return Self.suggestion(from: prior.text, to: t2)
    }

    private func record(_ text: String, at now: Date) {
        guard !text.isEmpty else { return }
        recents.insert(Recent(text: text, at: now), at: 0)
        if recents.count > maxRecents { recents.removeLast(recents.count - maxRecents) }
    }

    // MARK: - Qualification (pure — unit-testable, §5.4 gates a–d)

    /// All §5.4 gates, in order. Returns the `.term` candidate or nil.
    static func suggestion(from t1: String, to t2: String) -> Suggestion? {
        let a = t1.precomposedStringWithCanonicalMapping
        let b = t2.precomposedStringWithCanonicalMapping
        guard a != b else { return nil }

        // (a.1) LOOSE whole-string floor — only rejects two unrelated sentences.
        // The strict near-homophone test runs on the changed region (a.4b), so a
        // short re-dictation ("Hai Noi" → "Hà Nội", whole-sim 0.57) is no longer
        // rejected just for being a small fraction of nothing.
        guard normalizedSimilarity(a, b) >= 0.5 else { return nil }

        // (a.2) Reuse CorrectionDiff to isolate the changed token-region. nil means
        // no learnable change (identical / punctuation-only).
        guard let change = CorrectionDiff.extractChange(from: a, to: b) else { return nil }

        // (a.3–c) Run the shared near-homophone gate on the localized change. This
        // is the SINGLE source of truth shared with Signal A (CorrectionWatcher) so
        // the two paths can never drift.
        guard qualifiesAsLearnable(wrong: change.wrong, right: change.right) else { return nil }

        return Suggestion(wrong: change.wrong, right: change.right)
    }

    /// The shared near-homophone learnability gate (§5.4 gates a.3–c), operating on
    /// an already-localized (wrong, right) change region. A qualifying pair is a
    /// single localized near-homophone that ADDS diacritics/structure (proper-noun
    /// direction) and is not a common word. Used by both Signal B (re-dictation,
    /// `suggestion` above) and Signal A (AX read-back, `CorrectionWatcher`) so there
    /// is exactly ONE gate, never two drifting copies. Pure / unit-testable.
    static func qualifiesAsLearnable(wrong: String, right: String) -> Bool {
        // (a.3) SINGLE token-region: the changed span on each side is one region.
        // Multi-token rewrites are not near-homophone corrections — skip them.
        let wrongTokens = wrong.split(whereSeparator: { $0.isWhitespace })
        let rightTokens = right.split(whereSeparator: { $0.isWhitespace })
        // Allow the corrected side to merge/split spacing of the same syllables
        // ("Hai Noi" → "Haynoi"), but cap both sides at 2 orthographic tokens.
        guard wrongTokens.count <= 2, rightTokens.count <= 2 else { return false }

        // (a.4) Small per-token edit distance — near-homophone, not a different word.
        // Compare the joined (spaces removed) forms so "Hai Noi" vs "Haynoi" reads as
        // a 0-ish edit, not a whitespace blowup.
        let wrongJoined = wrong.replacingOccurrences(of: " ", with: "")
        let rightJoined = right.replacingOccurrences(of: " ", with: "")
        guard levenshtein(wrongJoined.lowercased(), rightJoined.lowercased()) <= maxTokenEditDistanceConst else { return false }

        // (a.4b) Similarity floor on the CHANGED region itself (joined forms) — the
        // real near-homophone gate, independent of surrounding sentence length.
        guard normalizedSimilarity(wrongJoined, rightJoined) >= 0.5 else { return false }

        // (b) Diacritic-direction asymmetry: qualify ONLY when `right` ADDS
        // diacritics / structure that `wrong` lacked — never the reverse.
        guard addsDiacriticsOrStructure(wrong: wrong, right: right) else { return false }

        // (c) Real common-word stoplist (VI + EN). Skip common words.
        guard !isCommonWord(right) else { return false }

        return true
    }

    /// Static mirror of `maxTokenEditDistance` for use from the static gate.
    private static let maxTokenEditDistanceConst = 4

    // MARK: - Similarity / distance helpers

    /// Normalized similarity in [0, 1] = 1 − (edit distance / max length), on the
    /// case-folded NFC strings. 1.0 = identical, 0 = totally different.
    static func normalizedSimilarity(_ a: String, _ b: String) -> Double {
        let x = a.lowercased()
        let y = b.lowercased()
        if x == y { return 1 }
        let maxLen = max(x.count, y.count)
        guard maxLen > 0 else { return 1 }
        let d = levenshtein(x, y)
        return 1 - (Double(d) / Double(maxLen))
    }

    /// Classic Levenshtein edit distance on Character arrays. Small inputs.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a)
        let t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }

    // MARK: - Diacritic-direction asymmetry (§5.4 gate b)

    /// True when `right` adds diacritics or capitalization/structure the `wrong`
    /// lacked, and NOT the reverse. The asymmetry guard: a re-dictation that STRIPS
    /// diacritics ("Sơn" → "Son") must never be suggested — that is exactly the
    /// self-poisoning direction the VI design fears.
    static func addsDiacriticsOrStructure(wrong: String, right: String) -> Bool {
        let wMarks = combiningMarkCount(wrong)
        let rMarks = combiningMarkCount(right)
        // Adds diacritics → suggest. Removes diacritics → never.
        if rMarks > wMarks { return true }
        if rMarks < wMarks { return false }

        // Equal diacritics: allow if `right` adds capital-letter structure the wrong
        // lacked (e.g. "haynoi" → "Haynoi"), which is the proper-noun direction.
        let wUpper = wrong.filter { $0.isUppercase }.count
        let rUpper = right.filter { $0.isUppercase }.count
        return rUpper > wUpper
    }

    /// Count of combining (diacritic) marks after NFD decomposition.
    private static func combiningMarkCount(_ s: String) -> Int {
        s.decomposedStringWithCanonicalMapping.unicodeScalars.reduce(0) {
            $0 + ($1.properties.canonicalCombiningClass != .notReordered ? 1 : 0)
        }
    }

    // MARK: - Common-word stoplist (§5.4 gate c)

    /// True when `term` is a high-frequency VI or EN common word (skip learning it).
    /// Compares the whole candidate against the joined form too, so a 2-token span
    /// that is just two common words is also rejected.
    static func isCommonWord(_ term: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
        guard !t.isEmpty else { return true }
        if stopwords.contains(t) { return true }
        // Every sub-token a stopword (e.g. "của tôi") → common phrase.
        let toks = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !toks.isEmpty, toks.allSatisfy({ stopwords.contains($0) }) { return true }
        return false
    }

    /// High-frequency VI + EN words. Deliberately a real stoplist (NOT "has
    /// diacritics ⇒ proper noun" — VI common words are full of diacritics: người,
    /// được, điều). Kept compact but covers the words a re-dictation diff would
    /// most often land on. NFC-normalized, lowercase.
    private static let stopwords: Set<String> = {
        let vi = [
            "tôi", "bạn", "anh", "chị", "em", "nó", "họ", "mình", "chúng", "ta",
            "là", "và", "của", "có", "không", "được", "này", "đó", "kia", "ấy",
            "một", "hai", "ba", "những", "các", "cái", "người", "việc", "điều",
            "khi", "nếu", "thì", "mà", "với", "cho", "từ", "đến", "ở", "trong",
            "ngoài", "trên", "dưới", "ra", "vào", "lên", "xuống", "về", "rồi",
            "đã", "đang", "sẽ", "vẫn", "cũng", "rất", "quá", "lắm", "nhé", "nha",
            "ạ", "vâng", "dạ", "ừ", "à", "ờ", "thôi", "đi", "làm", "nói", "biết",
            "thấy", "muốn", "phải", "nên", "cần", "như", "vậy", "sao", "gì", "ai",
            "nào", "đâu", "bao", "giờ", "ngày", "năm", "lúc", "hôm", "nay", "qua",
        ]
        let en = [
            "the", "a", "an", "and", "or", "but", "if", "of", "to", "in", "on",
            "at", "by", "for", "with", "from", "as", "is", "are", "was", "were",
            "be", "been", "being", "am", "do", "does", "did", "have", "has", "had",
            "this", "that", "these", "those", "it", "its", "i", "you", "he", "she",
            "we", "they", "me", "him", "her", "us", "them", "my", "your", "his",
            "our", "their", "what", "when", "where", "who", "how", "why", "which",
            "not", "no", "yes", "can", "will", "would", "should", "could", "may",
            "so", "just", "very", "really", "now", "then", "there", "here", "ok",
            "okay", "one", "two", "three", "yeah", "yep", "thing", "stuff",
        ]
        return Set(vi + en)
    }()
}
