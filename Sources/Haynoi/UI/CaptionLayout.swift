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

    /// Grow-only lock: committed words stay put (Vietnamese diacritics included).
    /// Bold is only the live tail after the lock. Sentence-end commits everything.
    static func advanceLock(raw: String, locked: String) -> (committed: String, fresh: String, newLock: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            return ("", "", "")
        }
        let parts = split(t)
        if parts.fresh.isEmpty {
            return (t, "", t)
        }
        var newLock = parts.committed
        if !locked.isEmpty, t.hasPrefix(locked) {
            if parts.committed.hasPrefix(locked) {
                newLock = parts.committed
            } else {
                newLock = locked
            }
        }
        let fresh: String
        if !newLock.isEmpty, t.hasPrefix(newLock) {
            fresh = String(t.dropFirst(newLock.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            newLock = parts.committed
            fresh = parts.fresh
        }
        return (newLock, fresh, newLock)
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
