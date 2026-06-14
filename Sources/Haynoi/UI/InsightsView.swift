import SwiftUI
import AppKit

// MARK: - InsightsView (F2 — usage identity surface)
//
// Obsidian Instrument / light-b-paper-v2 restyle (2026-06-14).
// Token source: ObsidianTokens.swift
//
// Six widgets rendered in a single scrollable page:
//   (a) Hero sentence with comparison ladder
//   (b) Stat strip: 4 cards — words / WPM / streak / best streak
//   (c) 16-week heatmap — Monday-first, 5-bucket Signal Cyan intensity
//   (d) Per-app destination breakdown (top 5 + remainder)
//
// Refresh: onAppear + .haynoiDictationCompleted notification (F2.6 — no timers).
// Migration: seeds daily map + longest streak on first render (D13).

struct InsightsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    @State private var insights = UsageTracker.InsightsData(dailyWords: [:], appWords: [:])

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                statStripSection
                insightsDivider
                heatmapSection
                insightsDivider
                appBreakdownSection
            }
            .padding(.bottom, C.s7)
        }
        .background(Color.obsidianBackground(for: scheme))
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .haynoiDictationCompleted)) { _ in
            refresh()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        let pairs = state.transcriptions.map {
            (timestamp: $0.timestamp, wordCount: $0.wordCount)
        }
        UsageTracker.runMigrationIfNeeded(transcriptions: pairs)
        insights = UsageTracker.loadInsights()

        if MilestoneTracker.hasUnseenMilestone {
            MilestoneTracker.clearUnseenFlag()
        }
    }

    // MARK: - (a) Hero Section

    private var heroSection: some View {
        let total = UsageTracker.totalWords
        // Build the hero sentence with distinct typography for the number
        let text = heroText(total: total)
        return Text(text)
            .font(.obsidianBody)
            .lineSpacing(4)
            .foregroundStyle(Color.obsidianLabel2(for: scheme))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, C.s6)
            .padding(.top, C.s5)
            .padding(.bottom, C.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - (b) Stat Strip — 4 cards on one row

    private var statStripSection: some View {
        let wpm      = UsageTracker.wordsPerMinute
        let current  = UsageTracker.streakDays
        let longest  = UsageTracker.longestStreakDays

        return HStack(spacing: C.s3) {
            insightCard(
                value: formatShort(UsageTracker.totalWords),
                label: "Words spoken",
                isAccent: false
            )
            insightCard(
                value: wpm > 0 ? "\(wpm)" : "—",
                label: "Avg WPM",
                isAccent: false
            )
            insightCard(
                value: "\(current)",
                label: current == 1 ? "Day streak" : "Day streak",
                isAccent: current > 0          // amber label when active
            )
            insightCard(
                value: "\(longest)",
                label: "Best streak",
                isAccent: false
            )
        }
        .padding(.horizontal, C.s6)
        .padding(.bottom, C.s5)
    }

    /// Stat card — mono tabular value, uppercase label, Signal Cyan deep value when isAccent.
    private func insightCard(value: String, label: String, isAccent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // LABEL row — uppercase 10/600, muted
            Text(label.uppercased())
                .font(.obsidianLabel)
                .kerning(0.8)
                .foregroundStyle(Color.obsidianLabel3(for: scheme))

            // VALUE — JetBrains Mono 26pt tabular; cyan-deep when accent (streak active)
            Text(value)
                .font(Font.custom("JetBrainsMono-Regular", size: 26).monospacedDigit())
                .foregroundStyle(
                    isAccent
                        ? Color.obsidianAccent(for: scheme)
                        : Color.obsidianLabel(for: scheme)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)     // safety: never clips the number
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, C.s4)
        .padding(.vertical, C.s4)
        .background(Color.obsidianSurface(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: C.rMD))
        .overlay(
            RoundedRectangle(cornerRadius: C.rMD)
                .stroke(Color.obsidianDivider(for: scheme), lineWidth: 1)
        )
    }

    private func formatShort(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...:    return String(format: "%.1fK", Double(n) / 1_000)
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    // MARK: - (c) Heatmap Section

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: C.s3) {
            sectionLabel("16-Week Activity")
            HeatmapGrid(dailyWords: insights.dailyWords, scheme: scheme)
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, C.s5)
    }

    // MARK: - (d) Per-app Breakdown Section

    private var appBreakdownSection: some View {
        let total = UsageTracker.totalWords
        let appMap = insights.appWords
        // Merge duplicate display names, sort by words, take top 5
        var merged: [String: (bundleId: String, words: Int)] = [:]
        for (bundleId, app) in appMap {
            if var existing = merged[app.displayName] {
                existing.words += app.words
                merged[app.displayName] = existing
            } else {
                merged[app.displayName] = (bundleId, app.words)
            }
        }
        let topEntries = merged
            .map { (key: $0.value.bundleId, value: (displayName: $0.key, words: $0.value.words)) }
            .sorted { $0.value.words > $1.value.words }
            .prefix(5)
        let attributedSum = appMap.values.reduce(0) { $0 + $1.words }
        let remainder = max(0, total - attributedSum)

        return VStack(alignment: .leading, spacing: C.s3) {
            sectionLabel("Where Your Words Go")
            if topEntries.isEmpty && remainder == 0 {
                Text("Per-app breakdown will appear after new dictations.")
                    .font(.obsidianCaption)
                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    .padding(.top, 2)
            } else {
                // Apps card — white surface, hairline border, stacked rows
                VStack(spacing: 0) {
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
                .background(Color.obsidianSurface(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: C.rMD))
                .overlay(
                    RoundedRectangle(cornerRadius: C.rMD)
                        .stroke(Color.obsidianDivider(for: scheme), lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, C.s5)
    }

    // MARK: - Helpers

    private var insightsDivider: some View {
        Rectangle()
            .fill(Color.obsidianDivider(for: scheme))
            .frame(height: 1)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.obsidianLabel)
            .foregroundStyle(Color.obsidianLabel3(for: scheme))
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
// Intensity: 5 Signal-Cyan buckets relative to user's own max-day.
// Today: Signal Cyan outline stroke. Future cells: bare canvas, no stroke.
// Past zero-word days: lightest cyan tint bucket WITH soft stroke.
//
// Obsidian light-b-paper-v2 bucket stops (from mockup):
//   h0  rgba(56,225,198, 0.06)  border rgba(56,225,198, 0.05)
//   h1  rgba(56,225,198, 0.15)  border rgba(56,225,198, 0.09)
//   h2  rgba(56,225,198, 0.30)  border rgba(56,225,198, 0.16)
//   h3  rgba(56,225,198, 0.52)  border rgba(56,225,198, 0.26)
//   h4  rgba(56,225,198, 0.85)  border rgba(56,225,198, 0.48)
//   today: 1.5px Signal Cyan ring (#38E1C6)

private struct HeatmapGrid: View {
    let dailyWords: [String: Int]
    let scheme: ColorScheme

    // Build a 16-week Monday-first grid. Returns array of 16 week-columns.
    private var gridCells: [[HeatmapCell]] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday — locale-independent
        let today = Date()

        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        comps.weekday = 2 // Monday
        guard let thisMonday = cal.date(from: comps) else { return [] }
        guard let startMonday = cal.date(byAdding: .weekOfYear, value: -15, to: thisMonday) else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"

        let maxWords = dailyWords.values.max() ?? 0

        var columns: [[HeatmapCell]] = []
        for col in 0..<16 {
            var rows: [HeatmapCell] = []
            for row in 0..<7 {
                let dayOffset = col * 7 + row
                guard let date = cal.date(byAdding: .day, value: dayOffset, to: startMonday) else { continue }
                let key = fmt.string(from: date)
                let words = dailyWords[key] ?? 0
                let isToday = cal.isDateInToday(date)
                let isFuture = date > today && !isToday
                let isPast = !isToday && !isFuture
                let bkt = isFuture ? -1 : bucket(words: words, max: maxWords, isPast: isPast)
                rows.append(HeatmapCell(
                    dateKey: key, displayDate: fmt.string(from: date),
                    words: words, bucket: bkt,
                    isToday: isToday, isFuture: isFuture, isPast: isPast
                ))
            }
            columns.append(rows)
        }
        return columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                // Day-of-week axis (Mon–Sun)
                let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(0..<dayLabels.count, id: \.self) { i in
                        Text(dayLabels[i])
                            .font(Font.custom("JetBrainsMono-Regular", size: 8))
                            .foregroundStyle(Color.obsidianLabel4(for: scheme))
                            .frame(width: 10, height: 11, alignment: .trailing)
                    }
                }
                // Week columns (oldest left, current right)
                ForEach(0..<gridCells.count, id: \.self) { col in
                    VStack(spacing: 3) {
                        ForEach(0..<gridCells[col].count, id: \.self) { row in
                            cellView(cell: gridCells[col][row])
                        }
                    }
                }
            }

            // Intensity legend
            HStack(spacing: 5) {
                Text("Less")
                    .font(Font.custom("JetBrainsMono-Regular", size: 8.5))
                    .foregroundStyle(Color.obsidianLabel4(for: scheme))
                ForEach(0..<5, id: \.self) { b in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bucketFill(bucket: b))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(bucketStroke(bucket: b), lineWidth: 1)
                        )
                        .frame(width: 11, height: 11)
                }
                Text("More")
                    .font(Font.custom("JetBrainsMono-Regular", size: 8.5))
                    .foregroundStyle(Color.obsidianLabel4(for: scheme))
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func cellView(cell: HeatmapCell) -> some View {
        ZStack {
            if cell.isFuture {
                // Future: bare canvas, no stroke
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.obsidianBackground(for: scheme))
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(bucketFill(bucket: cell.bucket))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(bucketStroke(bucket: cell.bucket), lineWidth: 1)
                    )
                if cell.isToday {
                    // Signal Cyan ring for today
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accent, lineWidth: 1.5)
                }
            }
        }
        .frame(width: 11, height: 11)
        .help(cell.isFuture ? "" : "\(cell.displayDate): \(cell.words) words")
    }

    // Fill colours matched to light-b-paper-v2 CSS h0–h4 classes
    private func bucketFill(bucket: Int) -> Color {
        switch bucket {
        case 0:  return Color.accent.opacity(0.06)
        case 1:  return Color.accent.opacity(0.15)
        case 2:  return Color.accent.opacity(0.30)
        case 3:  return Color.accent.opacity(0.52)
        case 4:  return Color.accent.opacity(0.85)
        default: return Color.obsidianBackground(for: scheme)
        }
    }

    private func bucketStroke(bucket: Int) -> Color {
        switch bucket {
        case 0:  return Color.accent.opacity(0.05)
        case 1:  return Color.accent.opacity(0.09)
        case 2:  return Color.accent.opacity(0.16)
        case 3:  return Color.accent.opacity(0.26)
        case 4:  return Color.accent.opacity(0.48)
        default: return .clear
        }
    }

    private func bucket(words: Int, max: Int, isPast: Bool) -> Int {
        guard isPast else { return 0 }
        guard words > 0, max > 0 else { return 0 }
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
    let bucket: Int    // -1 = future
    let isToday: Bool
    let isFuture: Bool
    let isPast: Bool
}

// MARK: - AppWordRow (F2.4d — per-app breakdown)
//
// Obsidian redesign: rows sit inside a card (white surface + hairline),
// separated by a soft hairline. Bar uses Signal Cyan gradient.
// Word count: JetBrains Mono tabular. App name: Be Vietnam Pro.

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
                        .font(.system(size: 13))
                        .foregroundStyle(Color.obsidianLabel3(for: scheme))
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            // Name
            Text(displayName)
                .font(.obsidianCaption)
                .foregroundStyle(Color.obsidianLabel2(for: scheme))
                .lineLimit(1)

            Spacer()

            // Progress bar (fixed 88pt wide — matches mockup)
            GeometryReader { _ in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.obsidianHover(for: scheme))
                        .frame(width: 88, height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [Color.accent, Color.accentDeep],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: 88 * shareFraction, height: 4)
                }
            }
            .frame(width: 88, height: 4)

            // Word count — JetBrains Mono tabular, 11pt
            Text(formattedWords)
                .font(Font.custom("JetBrainsMono-Regular", size: 11).monospacedDigit())
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, C.s5)
        .padding(.vertical, C.s3)
        .background(Color.obsidianSurface(for: scheme))
        // Hairline separator between rows (drawn as bottom overlay)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.obsidianDivider(for: scheme).opacity(0.5))
                .frame(height: 1)
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
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 22, height: 22)
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

    static func latestMilestone(for total: Int) -> Milestone? {
        let achieved = thresholds.filter { total >= $0 }
        guard let highest = achieved.last else { return nil }
        return Milestone(threshold: highest)
    }

    static var hasUnseenMilestone: Bool {
        UserDefaults.standard.bool(forKey: unseenKey)
    }

    static func markUnseenIfNeeded(previousTotal: Int, newTotal: Int) {
        let crossed = thresholds.contains { previousTotal < $0 && newTotal >= $0 }
        if crossed {
            UserDefaults.standard.set(true, forKey: unseenKey)
        }
    }

    static func clearUnseenFlag() {
        UserDefaults.standard.set(false, forKey: unseenKey)
    }
}
