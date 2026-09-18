import AppKit

/// Live-speech caption pill. Matches Superwhisper video `960d0b1a2bc6`
/// (tamarajtran, 17 Sep): bottom pill, committed regular, newest tail bold.
enum CaptionLayout {
    static let fontSize: CGFloat = 15
    static let maxWidthFraction: CGFloat = 0.56
    static let minWidth: CGFloat = 176
    static let height: CGFloat = 44
    static let chromeWidth: CGFloat = 72 // trail + padding + caret
    static let freshWordCount = 3

    /// Last `freshWordCount` words are the streaming tail. A trailing
    /// sentence end-mark commits the whole line (no bold).
    static func split(_ raw: String) -> (committed: String, fresh: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return ("", "") }
        if let last = t.last, ".!?…".contains(last) {
            return (t, "")
        }
        let parts = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if parts.count <= freshWordCount {
            return ("", t)
        }
        let fresh = parts.suffix(freshWordCount).joined(separator: " ")
        let committed = parts.dropLast(freshWordCount).joined(separator: " ")
        return (committed, fresh)
    }

    /// Grow-only lock so a committed Vietnamese token is not redrawn when
    /// later partials restyle diacritics. If the lock is no longer a prefix,
    /// fall back to `split`.
    static func advanceLock(raw: String, locked: String) -> (committed: String, fresh: String, newLock: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            return ("", "", "")
        }
        if !locked.isEmpty, t.hasPrefix(locked) {
            let rest = String(t.dropFirst(locked.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (locked, rest, locked)
        }
        let parts = split(t)
        return (parts.committed, parts.fresh, parts.committed)
    }

    static func pillWidth(for raw: String, screenWidth: CGFloat) -> CGFloat {
        let parts = split(raw)
        let text = [parts.committed, parts.fresh].filter { !$0.isEmpty }.joined(separator: " ")
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let textW = (text as NSString).size(withAttributes: [.font: font]).width
        let maxW = screenWidth * maxWidthFraction
        return min(max(minWidth, ceil(textW) + chromeWidth), maxW)
    }
}
