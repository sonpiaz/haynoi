import AppKit

/// Option A locked 17 Sep: frosted pill, fixed narrow width, text scrolls
/// left so the newest words stay on the right. Bold = uncommitted tail.
enum CaptionLayout {
    /// Smaller than the 32.14 pill (14/32) and the mockup's 18pt.
    static let fontSize: CGFloat = 13
    static let height: CGFloat = 28
    static let widthFraction: CGFloat = 0.24
    static let minWidth: CGFloat = 360
    static let maxWidth: CGFloat = 420
    static let freshWordCount = 3
    static let menuGap: CGFloat = 8

    /// The pill shows ~60 characters. A long hold now keeps every utterance,
    /// so cap what the marquee lays out; it only ever shows the right end.
    static let maxChars = 240

    static func tail(_ text: String) -> String {
        guard text.count > maxChars else { return text }
        let end = text.suffix(maxChars)
        guard let space = end.firstIndex(of: " ") else { return String(end) }
        return String(end[end.index(after: space)...])
    }

    static func fixedWidth(screenWidth: CGFloat) -> CGFloat {
        min(maxWidth, max(minWidth, (screenWidth * widthFraction).rounded()))
    }

    static func pillSize(screenWidth: CGFloat) -> NSSize {
        NSSize(width: fixedWidth(screenWidth: screenWidth), height: height)
    }

    /// Width does not depend on the transcript — Son locked a fixed frame.
    static func pillWidth(for raw: String, screenWidth: CGFloat) -> CGFloat {
        _ = raw
        return fixedWidth(screenWidth: screenWidth)
    }

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
}
