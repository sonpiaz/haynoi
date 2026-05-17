import Foundation

/// Simple local usage counter with gamification.
/// Tracks: transcriptions, words, streak days, WPM.
enum UsageTracker {
    private static let defaults = UserDefaults.standard
    private static let monthlyKey = "usage_"
    private static let dailyKey = "usageDay_"
    private static let wordsKey = "totalWordsAllTime"
    private static let totalSecondsKey = "totalDictationSeconds"
    private static let lastActiveDayKey = "lastActiveDay"
    private static let streakKey = "currentStreak"

    // MARK: - Record

    static func recordTranscription(wordCount: Int = 0, durationSeconds: Double = 0) {
        // Monthly count
        let mKey = currentMonthKey()
        defaults.set(defaults.integer(forKey: mKey) + 1, forKey: mKey)

        // Total words
        defaults.set(defaults.integer(forKey: wordsKey) + wordCount, forKey: wordsKey)

        // Total dictation seconds
        defaults.set(defaults.double(forKey: totalSecondsKey) + durationSeconds, forKey: totalSecondsKey)

        // Streak
        updateStreak()
    }

    // MARK: - Stats

    static var currentMonthCount: Int {
        defaults.integer(forKey: currentMonthKey())
    }

    static var totalWords: Int {
        defaults.integer(forKey: wordsKey)
    }

    /// Average words per minute across all dictation time
    static var wordsPerMinute: Int {
        let totalMin = defaults.double(forKey: totalSecondsKey) / 60.0
        guard totalMin > 0.1 else { return 0 }
        return Int(Double(defaults.integer(forKey: wordsKey)) / totalMin)
    }

    static var streakDays: Int {
        // Check if streak is still valid (used today or yesterday)
        let today = dayString(Date())
        let lastActive = defaults.string(forKey: lastActiveDayKey) ?? ""
        if lastActive == today { return defaults.integer(forKey: streakKey) }

        let yesterday = dayString(Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        if lastActive == yesterday { return defaults.integer(forKey: streakKey) }

        // Streak broken
        return 0
    }

    static var stats: [(month: String, count: Int)] {
        let allKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(monthlyKey) }
            .sorted()
            .reversed()
        return allKeys.prefix(12).map { key in
            let month = String(key.dropFirst(monthlyKey.count))
            return (month: month, count: defaults.integer(forKey: key))
        }
    }

    // MARK: - Private

    private static func updateStreak() {
        let today = dayString(Date())
        let lastActive = defaults.string(forKey: lastActiveDayKey) ?? ""

        if lastActive == today { return } // already counted today

        let yesterday = dayString(Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        if lastActive == yesterday {
            // Consecutive day — increment streak
            defaults.set(defaults.integer(forKey: streakKey) + 1, forKey: streakKey)
        } else {
            // Streak broken — start new
            defaults.set(1, forKey: streakKey)
        }
        defaults.set(today, forKey: lastActiveDayKey)
    }

    private static func currentMonthKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return monthlyKey + f.string(from: Date())
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
