import SwiftUI
import AppKit

// MARK: - InsightsView (F2 — usage identity surface)
//
// Six widgets rendered in a single scrollable Mercury page:
//   (a) Hero sentence with comparison ladder
//   (b) WPM stat (hidden below 30 s cumulative tracked audio, D29)
//   (c) Streak block: current + longest ever (D12)
//   (d) 16-week heatmap — Monday-first, 5-bucket indigo intensity (D20/D30)
//   (e) Per-app destination breakdown (top 5 + remainder)
//   (f) Milestone line + Copy button (D15/D16/D27)
//
// Refresh: onAppear + .haynoiDictationCompleted notification (F2.6 — no timers).
// Migration: seeds daily map + longest streak on first render (D13).

struct InsightsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var insights = UsageTracker.InsightsData(dailyWords: [:], appWords: [:])
    @State private var milestoneCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                insightsDivider
                wpmSection
                insightsDivider
                streakSection
                insightsDivider
                heatmapSection
                insightsDivider
                appBreakdownSection
                milestoneSection
            }
            .padding(.bottom, C.s7)
        }
        .background(Color.calmBackground(for: scheme))
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .haynoiDictationCompleted)) { _ in
            refresh()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        // One-time migration: seed daily map from history + seed longest streak
        let pairs = state.transcriptions.map {
            (timestamp: $0.timestamp, wordCount: $0.wordCount)
        }
        UsageTracker.runMigrationIfNeeded(transcriptions: pairs)
        insights = UsageTracker.loadInsights()

        // Milestone unseen flag: clear it now that Insights page is displayed (D15)
        if MilestoneTracker.hasUnseenMilestone {
            MilestoneTracker.clearUnseenFlag()
        }
    }

    // MARK: - (a) Hero Section

    private var heroSection: some View {
        let total = UsageTracker.totalWords
        return VStack(alignment: .leading, spacing: C.s2) {
            Text(heroText(total: total))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.calmLabel(for: scheme))
                .fixedSize(horizontal: false, vertical: true)

            if total > 0, let comparison = comparisonLabel(total: total) {
                Text("About \(comparison) in length.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.calmLabel3(for: scheme))
            }
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, C.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - (b) WPM Section

    @ViewBuilder
    private var wpmSection: some View {
        let wpm = UsageTracker.wordsPerMinute
        if wpm > 0 {
            VStack(alignment: .leading, spacing: C.s1) {
                sectionLabel("Speaking pace")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(wpm)")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Color.calmLabel(for: scheme))
                        .monospacedDigit()
                    Text("words per minute")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.calmLabel3(for: scheme))
                }
                Text("Measured across timed dictations only.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
            .padding(.horizontal, C.s6)
            .padding(.vertical, C.s5)
        }
    }

    // MARK: - (c) Streak Section

    private var streakSection: some View {
        let current = UsageTracker.streakDays
        let longest = UsageTracker.longestStreakDays
        return VStack(alignment: .leading, spacing: C.s3) {
            sectionLabel("Consistency")
            HStack(spacing: C.s6) {
                streakStat(value: current, label: "current streak",
                           accent: current > 0 ? Color.calmWarn : Color.calmLabel4(for: scheme))
                streakStat(value: longest, label: "longest streak",
                           accent: Color.calmLabel3(for: scheme))
            }
            if current == 0 {
                Text("Dictate today to start a new streak.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, C.s5)
    }

    private func streakStat(value: Int, label: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(value)")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accent)
                    .monospacedDigit()
                Text(value == 1 ? "day" : "days")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.calmLabel5(for: scheme))
        }
    }

    // MARK: - (d) Heatmap Section

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: C.s3) {
            sectionLabel("Activity — last 16 weeks")
            HeatmapGrid(dailyWords: insights.dailyWords, scheme: scheme)
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, C.s5)
    }

    // MARK: - (e) Per-app Breakdown Section

    private var appBreakdownSection: some View {
        let total = UsageTracker.totalWords
        let appMap = insights.appWords
        // Sort map entries (key = bundleId) by words descending, take top 5.
        // Keyed by bundleId so two apps sharing a display name never collide.
        let topEntries = appMap.sorted { $0.value.words > $1.value.words }.prefix(5)
        let attributedSum = appMap.values.reduce(0) { $0 + $1.words }
        let remainder = max(0, total - attributedSum)

        return VStack(alignment: .leading, spacing: C.s3) {
            sectionLabel("Where your words go")
            if topEntries.isEmpty && remainder == 0 {
                Text("Per-app breakdown will appear after new dictations.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            } else {
                VStack(spacing: 6) {
                    ForEach(topEntries, id: \.key) { bundleId, app in
                        AppWordRow(bundleId: bundleId,
                                   displayName: app.displayName,
                                   words: app.words,
                                   totalWords: total,
                                   scheme: scheme)
                    }
                    if remainder > 0 {
                        AppWordRow(bundleId: nil,
                                   displayName: "Earlier dictations",
                                   words: remainder,
                                   totalWords: total,
                                   scheme: scheme)
                    }
                }
            }
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, C.s5)
    }

    // MARK: - (f) Milestone Section

    @ViewBuilder
    private var milestoneSection: some View {
        let total = UsageTracker.totalWords
        if let milestone = MilestoneTracker.latestMilestone(for: total) {
            insightsDivider
            VStack(alignment: .leading, spacing: C.s2) {
                HStack(spacing: C.s2) {
                    Text(milestoneText(milestone: milestone, total: total))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.calmLabel2(for: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        copyMilestoneText(milestone: milestone, total: total)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: milestoneCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(milestoneCopied ? "Copied" : "Copy")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(milestoneCopied ? Color.calmSuccess : Color.calmLabel3(for: scheme))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.calmSubtle(for: scheme), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.calmDivider(for: scheme), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.15), value: milestoneCopied)
                }
            }
            .padding(.horizontal, C.s6)
            .padding(.vertical, C.s4)
            .background(Color.calmSubtle(for: scheme))
        }
    }

    // MARK: - Helpers

    private var insightsDivider: some View {
        Rectangle()
            .fill(Color.calmDivider(for: scheme))
            .frame(height: 1)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.calmLabel5(for: scheme))
            .kerning(0.8)
    }

    // Hero text: below 10k shows plain count + quiet copy; 10k+ adds comparison (D14).
    private func heroText(total: Int) -> String {
        let isVi = resolveIsVi()
        let formatted = formatWordsLocalized(total)
        if total == 0 {
            return isVi
                ? "Bạn chưa nói gì — bắt đầu nào."
                : "You haven't spoken any words yet. Start dictating."
        }
        if total < 10_000 {
            return isVi
                ? "Bạn đã nói \(formatted) từ — đây là khởi đầu tốt."
                : "You have spoken \(formatted) words — a good beginning."
        }
        if let label = comparisonLabel(total: total) {
            return isVi
                ? "Bạn đã nói \(formatted) từ — tương đương \(label)."
                : "You have spoken \(formatted) words — the length of \(label)."
        }
        return isVi
            ? "Bạn đã nói \(formatted) từ."
            : "You have spoken \(formatted) words."
    }

    // D14 comparison ladder
    private func comparisonLabel(total: Int) -> String? {
        switch total {
        case 1_000_000...: return resolveIsVi() ? "một kệ sách" : "a library shelf"
        case 500_000...:   return resolveIsVi() ? "một tập bách khoa toàn thư" : "an encyclopedia volume"
        case 250_000...:   return resolveIsVi() ? "một bộ ba tiểu thuyết" : "a boxed trilogy"
        case 100_000...:   return resolveIsVi() ? "hai tiểu thuyết" : "two novels"
        case 50_000...:    return resolveIsVi() ? "một tiểu thuyết" : "a novel"
        case 25_000...:    return resolveIsVi() ? "một truyện vừa" : "a novella"
        case 10_000...:    return resolveIsVi() ? "một truyện ngắn" : "a short story"
        default:           return nil
        }
    }

    private func milestoneText(milestone: MilestoneTracker.Milestone, total: Int) -> String {
        let isVi = resolveIsVi()
        let label = comparisonLabel(total: total) ?? ""
        return isVi
            ? "Bạn đã đạt \(formatWordsLocalized(milestone.threshold)) từ — \(label)."
            : "You've reached \(formatWordsLocalized(milestone.threshold)) words — \(label)."
    }

    // D16/D27: clipboard copy line, locale-aware thousands separator
    private func copyMilestoneText(milestone: MilestoneTracker.Milestone, total: Int) {
        let isVi = resolveIsVi()
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = isVi ? Locale(identifier: "vi_VN") : Locale(identifier: "en_US")
        let n = fmt.string(from: NSNumber(value: total)) ?? "\(total)"
        let comparison = comparisonLabel(total: total) ?? ""
        let line: String
        if isVi {
            line = "Tôi đã nói \(n) từ qua Haynoi — khoảng \(comparison). haynoi.com"
        } else {
            line = "I've spoken \(n) words into Haynoi — about \(comparison). haynoi.com"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
        milestoneCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { milestoneCopied = false }
    }

    private func resolveIsVi() -> Bool {
        let hint = UserDefaults.standard.string(forKey: "languageHint") ?? "auto"
        if hint == "vi" { return true }
        if hint == "en" { return false }
        return Locale.current.language.languageCode?.identifier == "vi"
    }

    private func formatWordsLocalized(_ count: Int) -> String {
        let isVi = resolveIsVi()
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.locale = isVi ? Locale(identifier: "vi_VN") : Locale(identifier: "en_US")
        return fmt.string(from: NSNumber(value: count)) ?? "\(count)"
    }

}

// MARK: - HeatmapGrid (F2.4d / D20 / D30)
//
// 7 rows (Mon–Sun) × 16 columns (most-recent week rightmost).
// Intensity: 5 indigo-on-white buckets relative to user's own max-day.
// Today: outlined cell. Future cells: bare paper, no stroke.
// Past zero-word days: lightest bucket WITH stroke.

private struct HeatmapGrid: View {
    let dailyWords: [String: Int]
    let scheme: ColorScheme

    @State private var tooltip: (date: String, words: Int)? = nil

    // Build a 16-week Monday-first grid. Returns array of 112 cells (col 0 = oldest week).
    private var gridCells: [[HeatmapCell]] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday — locale-independent; prevents week-number drift
        let today = Date()

        // Find the Monday of the current week
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        comps.weekday = 2 // Monday
        guard let thisMonday = cal.date(from: comps) else { return [] }

        // Go back 15 more weeks
        guard let startMonday = cal.date(byAdding: .weekOfYear, value: -15, to: thisMonday) else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        // Max words in any single day (for relative bucketing)
        let maxWords = dailyWords.values.max() ?? 0

        var columns: [[HeatmapCell]] = []
        for col in 0..<16 {
            var rows: [HeatmapCell] = []
            for row in 0..<7 { // Mon=0 … Sun=6
                let dayOffset = col * 7 + row
                guard let date = cal.date(byAdding: .day, value: dayOffset, to: startMonday) else { continue }
                let key = fmt.string(from: date)
                let words = dailyWords[key] ?? 0
                let isToday = cal.isDateInToday(date)
                let isFuture = date > today && !isToday
                let isPast = !isToday && !isFuture
                let bucket = isFuture ? 0 : bucket(words: words, max: maxWords, isPast: isPast)
                rows.append(HeatmapCell(
                    dateKey: key, displayDate: fmt.string(from: date),
                    words: words, bucket: bucket,
                    isToday: isToday, isFuture: isFuture, isPast: isPast
                ))
            }
            columns.append(rows)
        }
        return columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Grid: day-of-week labels on the left, week columns to the right
            HStack(alignment: .top, spacing: 3) {
                // Vertical day labels (Mon–Sun)
                let dayLabels = ["M","T","W","T","F","S","S"]
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(0..<dayLabels.count, id: \.self) { i in
                        Text(dayLabels[i])
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Color.calmLabel5(for: scheme))
                            .frame(width: 10, height: 12, alignment: .trailing)
                    }
                }
                // Week columns (oldest at left, current week at right)
                ForEach(0..<gridCells.count, id: \.self) { col in
                    VStack(spacing: 3) {
                        ForEach(0..<gridCells[col].count, id: \.self) { row in
                            let cell = gridCells[col][row]
                            cellView(cell: cell)
                        }
                    }
                }
            }
            // Intensity legend
            HStack(spacing: 4) {
                Text("Less")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.calmLabel5(for: scheme))
                ForEach(0..<5, id: \.self) { b in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bucketFill(bucket: b, scheme: scheme))
                        .frame(width: 10, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.calmDivider(for: scheme), lineWidth: 0.5))
                }
                Text("More")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.calmLabel5(for: scheme))
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func cellView(cell: HeatmapCell) -> some View {
        let showStroke = !cell.isFuture
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(cellBackground(cell))
            if cell.isToday {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.calmAccent(for: scheme).opacity(0.7), lineWidth: 1.5)
            } else if showStroke {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.calmDivider(for: scheme), lineWidth: 0.5)
            }
        }
        .frame(width: 12, height: 12)
        .help(cell.isFuture ? "" : "\(cell.displayDate): \(cell.words) words")
    }

    private func cellBackground(_ cell: HeatmapCell) -> Color {
        if cell.isFuture {
            return Color.calmBackground(for: scheme)
        }
        return bucketFill(bucket: cell.bucket, scheme: scheme)
    }

    private func bucketFill(bucket: Int, scheme: ColorScheme) -> Color {
        // 0 = lightest (zero-word past day), 4 = darkest (highest day)
        let base = Color.calmBackground(for: scheme)
        switch bucket {
        case 0: return scheme == .dark
                    ? Color.calmDarkSidebar
                    : Color.calmSidebar
        case 1: return Color.calmAccent(for: scheme).opacity(0.10)
        case 2: return Color.calmAccent(for: scheme).opacity(0.28)
        case 3: return Color.calmAccent(for: scheme).opacity(0.50)
        case 4: return Color.calmAccent(for: scheme).opacity(0.78)
        default: return base
        }
    }

    private func bucket(words: Int, max: Int, isPast: Bool) -> Int {
        guard isPast else { return 0 }
        guard words > 0, max > 0 else { return 0 }  // zero-word past day = lightest bucket
        let frac = Double(words) / Double(max)
        switch frac {
        case 0.75...: return 4
        case 0.50...: return 3
        case 0.25...: return 2
        default:      return 1
        }
    }
}

private struct HeatmapCell {
    let dateKey: String
    let displayDate: String
    let words: Int
    let bucket: Int
    let isToday: Bool
    let isFuture: Bool
    let isPast: Bool
}

// MARK: - AppWordRow (F2.4e)

private struct AppWordRow: View {
    let bundleId: String?
    let displayName: String
    let words: Int
    let totalWords: Int
    let scheme: ColorScheme

    @State private var appIcon: NSImage? = nil

    var body: some View {
        HStack(spacing: C.s3) {
            // App icon
            Group {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: bundleId == nil ? "clock.arrow.circlepath" : "app.dashed")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
            }
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Name + share bar
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.calmLabel2(for: scheme))
                        .lineLimit(1)
                    Spacer()
                    Text(formattedWords)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                        .monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.calmSubtle(for: scheme))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [Color.calmAccent(for: scheme), Color.calmAccent(for: scheme).opacity(0.7)],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * shareFraction, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .onAppear { loadIcon() }
    }

    private var shareFraction: CGFloat {
        guard totalWords > 0 else { return 0 }
        return min(CGFloat(words) / CGFloat(totalWords), 1.0)
    }

    private var formattedWords: String {
        if words >= 1_000 { return String(format: "%.1fK", Double(words) / 1_000) }
        return "\(words)"
    }

    private func loadIcon() {
        guard let bundleId = bundleId else { return }
        // Try running app first, then installed-app lookup via NSWorkspace (D22)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 20, height: 20)
            self.appIcon = icon
        }
    }
}

// MARK: - MilestoneTracker (F2.4f / D15)

enum MilestoneTracker {
    struct Milestone {
        let threshold: Int
    }

    private static let thresholds = [10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
    private static let unseenKey = "insightsUnseenMilestone"

    /// The highest milestone achieved for the given total, or nil.
    static func latestMilestone(for total: Int) -> Milestone? {
        let achieved = thresholds.filter { total >= $0 }
        guard let highest = achieved.last else { return nil }
        return Milestone(threshold: highest)
    }

    /// True when a milestone was crossed since the last display.
    static var hasUnseenMilestone: Bool {
        UserDefaults.standard.bool(forKey: unseenKey)
    }

    /// Call after a dictation pushes total past a threshold.
    static func markUnseenIfNeeded(previousTotal: Int, newTotal: Int) {
        let crossed = thresholds.contains { previousTotal < $0 && newTotal >= $0 }
        if crossed {
            UserDefaults.standard.set(true, forKey: unseenKey)
        }
    }

    /// Clear after the milestone line is displayed (main window OR Insights page — D15).
    static func clearUnseenFlag() {
        UserDefaults.standard.set(false, forKey: unseenKey)
    }
}
