import Foundation

// MARK: - Phonetics (v2 Phase 4 — sound-alike matching)
//
// A compact phonetic key for VI + EN words, built for ONE job: deciding whether
// two spellings could be the same spoken word ("Afider"/"Affitor",
// "Xero"/"Zero", "trương"/"chương"). Not IPA, not linguistics — a consonant
// skeleton where letters the transcriber commonly confuses share a symbol.
//
// Vietnamese is treated tone- and vowel-quality-insensitively on purpose: tones
// and diacritic vowel quality are exactly what a misrecognition mangles, so
// they must not separate a wrong form from its intended form. The diacritic
// DIRECTION safety lives in CorrectionDetector's gates, not here.
//
// Phonetic proximity NEVER auto-promotes anything to a `.replacement` — it only
// widens Signal B's near-homophone net and names candidates for the Signal E
// correction pass (redesign/10-DICTATION-LEARNING-V2.md Phase 4).
enum Phonetics {

    /// Phonetic key of a word or short phrase (spaces ignored). Examples:
    /// "Sơn"/"Sun"/"Son" → "sn" · "Hà Nội"/"Haynoi"/"Hai Noi" → "an" ·
    /// "Affitor"/"Afider" → "aftr" · "Xero"/"Zero" → "sr" · "Eric"/"Erik" → "ark".
    static func key(for term: String) -> String {
        // Normalize: lowercase, đ→d, strip combining marks, letters only.
        let lowered = term.lowercased().replacingOccurrences(of: "đ", with: "d")
        let stripped = lowered.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0.properties.canonicalCombiningClass == .notReordered }
        let letters = String(String.UnicodeScalarView(stripped)).filter { $0.isLetter }
        let chars = Array(letters)

        var out: [Character] = []
        var i = 0
        func emit(_ c: Character) {
            if out.last != c { out.append(c) }  // collapse doubles
        }
        while i < chars.count {
            // Multi-letter units first (longest match wins).
            if matches(chars, at: i, "ngh") { emit("n"); i += 3; continue }
            if matches(chars, at: i, "ng") { emit("n"); i += 2; continue }
            if matches(chars, at: i, "gh") { emit("k"); i += 2; continue }
            if matches(chars, at: i, "ph") { emit("f"); i += 2; continue }
            if matches(chars, at: i, "tr") { emit("c"); i += 2; continue }
            if matches(chars, at: i, "ch") { emit("c"); i += 2; continue }

            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "a", "e", "i", "o", "u", "y":
                // Vowels carry the confusion, not the identity: keep only a
                // word-initial vowel marker, drop the rest.
                if out.isEmpty { out.append("a") }
            case "h", "w":
                break  // weak/glide — contributes nothing to the skeleton
            case "c":
                emit(next.map { "eiy".contains($0) } == true ? "s" : "k")
            case "g":
                emit(next.map { "eiy".contains($0) } == true ? "j" : "k")
            case "b", "p":
                emit("p")
            case "d", "t":
                emit("t")
            case "s", "z", "x":
                emit("s")
            case "f", "v":
                emit("f")
            case "k", "q":
                emit("k")
            default:
                emit(c)  // j l m n r and anything else keep themselves
            }
            i += 1
        }
        return String(out)
    }

    private static func matches(_ chars: [Character], at i: Int, _ pattern: String) -> Bool {
        let p = Array(pattern)
        guard i + p.count <= chars.count else { return false }
        for (offset, pc) in p.enumerated() where chars[i + offset] != pc { return false }
        return true
    }

    /// Could `a` and `b` be the same spoken word? Equal keys, or one slip in a
    /// key long enough that a single slip doesn't mean a different word.
    static func close(_ a: String, _ b: String) -> Bool {
        let ka = key(for: a)
        let kb = key(for: b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka == kb { return true }
        guard max(ka.count, kb.count) >= 3 else { return false }
        return editDistance(ka, kb) <= 1
    }

    /// Tiny local Levenshtein — keys are a handful of characters, and
    /// CorrectionDetector's copy is MainActor-isolated with its class.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
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
}
