import Foundation

/// Simple local usage counter with gamification.
/// Tracks: transcriptions, words, streak days, WPM.
/// F2 additions: longest streak (D12), daily word aggregate map (D13),
/// per-app cumulative word counters (D18), one-time migration flag (D13).
enum UsageTracker {
    private static let defaults = UserDefaults.standard
    private static let monthlyKey = "usage_"
    private static let dailyKey = "usageDay_"
    private static let wordsKey = "totalWordsAllTime"
    private static let totalSecondsKey = "totalDictationSeconds"
    // WPM uses its own paired counters: legacy builds accumulated words for
    // months before duration tracking existed, so words/totalSeconds is
    // poisoned (54K words over ~14 tracked minutes read as ~4000 WPM).
    private static let wpmWordsKey = "wpmTrackedWords"
    private static let wpmSecondsKey = "wpmTrackedSeconds"
    private static let lastActiveDayKey = "lastActiveDay"
    private static let streakKey = "currentStreak"

    // F2 / D12 — longest streak ever (monotonically increasing)
    private static let longestStreakKey = "longestStreak"

    // F2 / D13 — path to the small JSON beside history.json in Application Support
    static let insightsFileURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Haynoi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("insights.json")
    }()

    // F2 migration flag — set after the one-time history scan completes
    private static let migrationDoneKey = "insightsMigrationDone"

    // MARK: - Record

    static func recordTranscription(wordCount: Int = 0, durationSeconds: Double = 0,
                                    appBundleId: String? = nil, appName: String? = nil) {
        // Monthly count
        let mKey = currentMonthKey()
        defaults.set(defaults.integer(forKey: mKey) + 1, forKey: mKey)

        // Total words
        defaults.set(defaults.integer(forKey: wordsKey) + wordCount, forKey: wordsKey)

        // Total dictation seconds
        defaults.set(defaults.double(forKey: totalSecondsKey) + durationSeconds, forKey: totalSecondsKey)

        // WPM pair — only count entries that carry BOTH words and duration,
        // so the average can never divide fresh words by missing time.
        if wordCount > 0, durationSeconds > 0 {
            defaults.set(defaults.integer(forKey: wpmWordsKey) + wordCount, forKey: wpmWordsKey)
            defaults.set(defaults.double(forKey: wpmSecondsKey) + durationSeconds, forKey: wpmSecondsKey)
        }

        // Streak (also updates longestStreak)
        updateStreak()

        // F2: update daily aggregate + per-app map in insights.json
        if wordCount > 0 {
            updateInsights(wordCount: wordCount, appBundleId: appBundleId, appName: appName)
        }
    }

    // MARK: - Stats

    static var currentMonthCount: Int {
        defaults.integer(forKey: currentMonthKey())
    }

    static var totalWords: Int {
        defaults.integer(forKey: wordsKey)
    }

    /// Average words per minute across dictations that tracked duration.
    /// Returns 0 (hidden in UI) until at least 30 s of paired data exists (D29).
    static var wordsPerMinute: Int {
        let totalSec = defaults.double(forKey: wpmSecondsKey)
        guard totalSec >= 30 else { return 0 }
        let totalMin = totalSec / 60.0
        return Int(Double(defaults.integer(forKey: wpmWordsKey)) / totalMin)
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

    /// F2 / D12 — longest streak ever; never decreases across relaunches.
    static var longestStreakDays: Int {
        defaults.integer(forKey: longestStreakKey)
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

    // MARK: - Insights JSON (F2 / D13 / D18)

    /// Persisted insights data: daily word counts and per-app cumulative totals.
    struct InsightsData: Codable {
        /// yyyy-MM-dd → word count (pruned to ~370 day-keys on write)
        var dailyWords: [String: Int]
        /// bundleId → AppWordTotal
        var appWords: [String: AppWordTotal]

        struct AppWordTotal: Codable {
            var displayName: String
            var words: Int
        }
    }

    /// Load insights from disk. Returns empty struct on any failure.
    static func loadInsights() -> InsightsData {
        guard let data = try? Data(contentsOf: insightsFileURL),
              let decoded = try? JSONDecoder().decode(InsightsData.self, from: data)
        else { return InsightsData(dailyWords: [:], appWords: [:]) }
        return decoded
    }

    /// Persist insights to disk on a background queue (atomic write).
    private static func saveInsights(_ data: InsightsData) {
        let url = insightsFileURL
        DispatchQueue.global(qos: .utility).async {
            guard let encoded = try? JSONEncoder().encode(data) else { return }
            try? encoded.write(to: url, options: .atomic)
        }
    }

    /// Increment daily aggregate and per-app counter after a new dictation.
    private static func updateInsights(wordCount: Int, appBundleId: String?, appName: String?) {
        var data = loadInsights()
        let today = dayString(Date())

        // Daily aggregate
        data.dailyWords[today, default: 0] += wordCount
        // Prune to ~370 most-recent day-keys (D20)
        if data.dailyWords.count > 370 {
            let sorted = data.dailyWords.keys.sorted()
            let toRemove = sorted.prefix(data.dailyWords.count - 370)
            toRemove.forEach { data.dailyWords.removeValue(forKey: $0) }
        }

        // Per-app cumulative counter — only when we have a bundle id (D18)
        if let bundleId = appBundleId {
            let name = appName ?? bundleId
            var entry = data.appWords[bundleId]
                ?? InsightsData.AppWordTotal(displayName: name, words: 0)
            entry.displayName = name  // latest localized name wins (D28)
            entry.words += wordCount
            data.appWords[bundleId] = entry
        }

        saveInsights(data)
    }

    // MARK: - One-time migration (F2 / D13)

    /// Run once on first Insights access: scan existing history entries to seed
    /// the daily map, and seed longest streak from current streak (D12).
    static func runMigrationIfNeeded(
        transcriptions: [(timestamp: Date, wordCount: Int)]
    ) {
        guard !defaults.bool(forKey: migrationDoneKey) else { return }

        // Seed longest streak from current streak value (D12)
        let current = streakDays
        if current > defaults.integer(forKey: longestStreakKey) {
            defaults.set(current, forKey: longestStreakKey)
        }

        // Seed daily map from history (D13)
        var data = loadInsights()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        for entry in transcriptions {
            let key = fmt.string(from: entry.timestamp)
            data.dailyWords[key, default: 0] += entry.wordCount
        }
        // Prune excess
        if data.dailyWords.count > 370 {
            let sorted = data.dailyWords.keys.sorted()
            let toRemove = sorted.prefix(data.dailyWords.count - 370)
            toRemove.forEach { data.dailyWords.removeValue(forKey: $0) }
        }
        saveInsights(data)

        defaults.set(true, forKey: migrationDoneKey)
    }

    // MARK: - Private

    private static func updateStreak() {
        let today = dayString(Date())
        let lastActive = defaults.string(forKey: lastActiveDayKey) ?? ""

        if lastActive == today { return } // already counted today

        let yesterday = dayString(Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
        let newStreak: Int
        if lastActive == yesterday {
            // Consecutive day — increment streak
            newStreak = defaults.integer(forKey: streakKey) + 1
            defaults.set(newStreak, forKey: streakKey)
        } else {
            // Streak broken — start new
            newStreak = 1
            defaults.set(newStreak, forKey: streakKey)
        }
        defaults.set(today, forKey: lastActiveDayKey)

        // F2 / D12: update longest streak (monotonically increasing)
        if newStreak > defaults.integer(forKey: longestStreakKey) {
            defaults.set(newStreak, forKey: longestStreakKey)
        }
    }

    private static func currentMonthKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return monthlyKey + f.string(from: Date())
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
