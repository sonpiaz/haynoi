import Foundation

/// Diffs the last transcript against its corrected version to extract a learnable
/// wrong → right pair (v1.1 Signal C, §7.1). When exactly one contiguous token
/// region differs, returns just that localized change ("Haynoi" → "Hà Nội");
/// otherwise (multi-region or whole-sentence rewrite) returns the whole strings.
enum CorrectionDiff {

    /// Returns the changed (wrong, right) pair, or nil when there is no real,
    /// learnable change (identical after NFC, or the change is only punctuation /
    /// whitespace).
    static func extractChange(from old: String, to new: String) -> (wrong: String, right: String)? {
        let o = old.precomposedStringWithCanonicalMapping
        let n = new.precomposedStringWithCanonicalMapping

        // No real change.
        guard o != n else { return nil }
        guard !o.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let oldTokens = tokens(o)
        let newTokens = tokens(n)

        // Longest common prefix.
        var prefix = 0
        while prefix < oldTokens.count, prefix < newTokens.count,
              oldTokens[prefix].caseInsensitiveCompare(newTokens[prefix]) == .orderedSame {
            prefix += 1
        }
        // Longest common suffix (not overlapping the prefix).
        var suffix = 0
        while suffix < (oldTokens.count - prefix), suffix < (newTokens.count - prefix),
              oldTokens[oldTokens.count - 1 - suffix].caseInsensitiveCompare(
                  newTokens[newTokens.count - 1 - suffix]) == .orderedSame {
            suffix += 1
        }

        let oldMid = Array(oldTokens[prefix..<(oldTokens.count - suffix)])
        let newMid = Array(newTokens[prefix..<(newTokens.count - suffix)])

        let wrong: String
        let right: String
        // A single localized contiguous changed region → learn just that span.
        // Both sides non-empty keeps it a genuine swap (not a pure insert/delete,
        // which doesn't generalize as a wrong→right rule). Otherwise fall back to
        // the whole strings per spec.
        if !oldMid.isEmpty, !newMid.isEmpty {
            wrong = oldMid.joined(separator: " ")
            right = newMid.joined(separator: " ")
        } else {
            wrong = o
            right = n
        }

        // Reject empty / punctuation-or-whitespace-only pairs.
        guard isLearnable(wrong), isLearnable(right) else { return nil }
        // A pure case/diacritic-equivalent change after trimming is no change.
        guard wrong.precomposedStringWithCanonicalMapping != right.precomposedStringWithCanonicalMapping else { return nil }
        return (wrong, right)
    }

    /// Whitespace-delimited tokens. Vietnamese multi-syllable phrases are handled
    /// by the contiguous changed region spanning several tokens.
    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// True when the string contains at least one letter or number — rejects
    /// punctuation-only / whitespace-only candidates.
    private static func isLearnable(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return t.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
