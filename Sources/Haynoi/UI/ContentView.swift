import SwiftUI
import Combine

// MARK: - ContentView (board "01" content area)
//
// The main-window content pane that sits to the right of the sidebar:
//   • Top STAT ROW — four cards in a grid:
//       (a) Day streak — big number + indigo aurora status dot
//       (b) Words transcribed — UsageTracker.totalWords (e.g. 54.4K)
//       (c) Avg words / min — UsageTracker.wordsPerMinute (e.g. 127)
//       (d) HOLD TO RECORD — distinct accent card showing the hotkey as keycaps
//   • HISTORY LIST — grouped by TODAY / YESTERDAY / date with a per-section
//     dictation count on the right; each row is a VI/EN language badge + the
//     transcript text + a meta line (relative time · word count · source app)
//     with a hover copy button.
//
// `mode` decides the page: .history shows the full grouped ledger; .recent shows
// only the most recent slice. Light Calm palette, generous calm spacing.

struct ContentView: View {
    enum Mode { case history, recent }

    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    @AppStorage("hotkeyChoice") private var hotkeyChoice = "option"

    var mode: Mode = .history

    private var recentLimit: Int { 8 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Stat row only on the History page (the board's stat strip).
                if mode == .history {
                    statRow
                        .padding(.bottom, 28)
                }

                if state.transcriptions.isEmpty {
                    emptyState
                } else {
                    historySections
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 28)
        }
        .background(Color.calmBackground(for: scheme))
    }

    // MARK: - Stat Row (4 cards)

    private var statRow: some View {
        // Board proportion: three equal stat cards + a wider (1.4×) hotkey card.
        HStack(spacing: 10) {
            // (a) Day streak — with the indigo aurora status dot
            statCard {
                HStack(spacing: 7) {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.calmAuroraCyan, .calmAuroraViolet],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 9, height: 9)
                        .shadow(color: Color.calmAuroraCyan.opacity(0.4), radius: 3)
                    Text("\(UsageTracker.streakDays)")
                        .font(.calmStatValue)
                        .monospacedDigit()
                        .foregroundStyle(Color.calmLabel(for: scheme))
                }
                statLabel("Day streak")
            }

            // (b) Words transcribed
            statCard {
                Text(formatWords(UsageTracker.totalWords))
                    .font(.calmStatValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.calmLabel(for: scheme))
                statLabel("Words transcribed")
            }

            // (c) Avg words / min
            statCard {
                Text(UsageTracker.wordsPerMinute > 0 ? "\(UsageTracker.wordsPerMinute)" : "—")
                    .font(.calmStatValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.calmLabel(for: scheme))
                statLabel("Avg words / min")
            }

            // (d) HOLD TO RECORD — distinct accent card with keycap chips
            hotkeyCard
        }
    }

    @ViewBuilder
    private func statCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.calmSurface(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.calmBorder, lineWidth: 1))
    }

    private func statLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.calmLabel4(for: scheme))
    }

    private var hotkeyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOLD TO RECORD")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color.calmAccent(for: scheme))
            HStack(spacing: 6) {
                keycap(hotkeySymbol)
                Text(hotkeyName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmLabel3(for: scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.calmActive(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.calmAccent(for: scheme).opacity(0.25), lineWidth: 1)
        )
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.calmLabel(for: scheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.calmSurface(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.calmHairline(for: scheme), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 1, y: 1)
    }

    private var hotkeySymbol: String {
        switch hotkeyChoice {
        case "command": return "⌘"
        case "control": return "⌃"
        case "fn":      return "fn"
        default:        return "⌥"
        }
    }

    private var hotkeyName: String {
        switch hotkeyChoice {
        case "command": return "Command"
        case "control": return "Control"
        case "fn":      return "Globe"
        default:        return "Left Option"
        }
    }

    // MARK: - History Sections

    private var historySections: some View {
        let groups = groupedTranscriptions
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
                sectionHeader(title: group.key, count: group.value.count)
                    .padding(.top, index == 0 ? 0 : 22)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(group.value) { entry in
                        HistoryRow(entry: entry, scheme: scheme) {
                            state.deleteTranscription(id: entry.id)
                        }
                    }
                }
                .background(Color.calmSurface(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.calmBorder, lineWidth: 1))
            }
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(0.7)
                .foregroundStyle(Color.calmLabel4(for: scheme))
            Spacer()
            Text("\(count) \(count == 1 ? "dictation" : "dictations")")
                .font(.system(size: 11))
                .foregroundStyle(Color.calmLabel4(for: scheme))
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)
            ZStack {
                Circle()
                    .fill(Color.calmAccentWash(for: scheme))
                    .frame(width: 72, height: 72)
                Image(systemName: "waveform.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.calmAccent(for: scheme))
            }
            VStack(spacing: 6) {
                Text("Your history is empty.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.calmLabel(for: scheme))
                Text("Hold \(HotkeyDisplay.symbolAndName) and speak — your words appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Grouping

    private static let groupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()

    private var groupedTranscriptions: [(key: String, value: [Transcription])] {
        let items = mode == .recent
            ? Array(state.transcriptions.prefix(recentLimit))
            : state.transcriptions

        let cal = Calendar.current
        let grouped = Dictionary(grouping: items) { entry -> String in
            if cal.isDateInToday(entry.timestamp) { return "Today" }
            if cal.isDateInYesterday(entry.timestamp) { return "Yesterday" }
            return Self.groupDateFormatter.string(from: entry.timestamp)
        }
        return grouped.sorted { a, b in
            (a.value.first?.timestamp ?? .distantPast) > (b.value.first?.timestamp ?? .distantPast)
        }
    }

    private func formatWords(_ count: Int) -> String {
        if count >= 1_000 { return String(format: "%.1fK", Float(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - History Row (board's clean hairline row)

struct HistoryRow: View {
    let entry: Transcription
    let scheme: ColorScheme
    let onDelete: () -> Void

    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            // Language badge
            let lang = detectLanguage(entry.text)
            Text(lang.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(lang == "vi" ? Color.calmWarn : Color.calmAccent(for: scheme))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    lang == "vi" ? Color.calmWarnBg : Color.calmAccentWash(for: scheme),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .padding(.top, 1)

            // Body: transcript + meta line
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.calmLabel(for: scheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                HStack(spacing: 5) {
                    Text(relativeTime)
                    metaDot
                    Text("\(entry.wordCount) words")
                    if let source = sourceApp {
                        metaDot
                        Text(source)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.calmLabel4(for: scheme))
            }

            // Hover actions — copy (board) + delete (engine affordance)
            if isHovered {
                HStack(spacing: 5) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(copied ? Color.calmSuccess : Color.calmLabel3(for: scheme))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .background(Color.calmSubtle(for: scheme), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.calmHairline(for: scheme), lineWidth: 1))
                    .help("Copy")

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { onDelete() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.calmWarn)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .background(Color.calmSubtle(for: scheme), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.calmHairline(for: scheme), lineWidth: 1))
                    .help("Delete")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(isHovered ? Color.calmHover(for: scheme) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.calmDivider(for: scheme))
                .frame(height: 1)
                .padding(.leading, 14)
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: copied)
        .onHover { isHovered = $0 }
    }

    private var metaDot: some View {
        Text("·").opacity(0.5)
    }

    private var sourceApp: String? {
        AppStyleDetector.displayName(bundleId: entry.appBundleId, fallback: entry.appName)
    }

    /// Relative time matching the board ("2 min ago", "1 hr ago", "Yesterday 4:12 PM").
    private var relativeTime: String {
        let cal = Calendar.current
        if cal.isDateInToday(entry.timestamp) {
            let secs = Int(Date().timeIntervalSince(entry.timestamp))
            switch secs {
            case ..<60:    return "Just now"
            case ..<120:   return "1 min ago"
            case ..<3600:  return "\(secs / 60) min ago"
            case ..<7200:  return "1 hr ago"
            default:       return "\(secs / 3600) hr ago"
            }
        }
        if cal.isDateInYesterday(entry.timestamp) {
            return "Yesterday \(Self.timeFmt.string(from: entry.timestamp))"
        }
        return "\(Self.dayFmt.string(from: entry.timestamp)) \(Self.timeFmt.string(from: entry.timestamp))"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private func detectLanguage(_ text: String) -> String {
        let viChars = CharacterSet(charactersIn: "àáảãạăắặằẵẳâấậầẫẩđèéẹẻẽêếệềễểìíịỉĩòóọỏõôốộồỗổơớợờỡởùúụủũưứựừữửỳýỵỷỹÀÁẢÃẠĂẮẶẰẴẲÂẤẬẦẪẨĐÈÉẸẺẼÊẾỆỀỄỂÌÍỊỈĨÒÓỌỎÕÔỐỘỒỖỔƠỚỢỜỠỞÙÚỤỦŨƯỨỰỪỮỬỲÝỴỶỸ")
        for char in text.unicodeScalars {
            if viChars.contains(char) { return "vi" }
        }
        return "en"
    }
}

// MARK: - Calm Level Bars (recording indicator — shared)

struct CalmLevelBars: View {
    let audioLevel: CGFloat
    let scheme: ColorScheme
    private let barCount = 8

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let phase = timeline.date.timeIntervalSinceReferenceDate * 2.4
                let barW: CGFloat = 3
                let gap: CGFloat = (size.width - CGFloat(barCount) * barW) / CGFloat(barCount - 1)
                let midY = size.height / 2

                for i in 0..<barCount {
                    let x = CGFloat(i) * (barW + gap)
                    let freq1 = sin(phase * 1.1 + Double(i) * 0.65) * 0.5 + 0.5
                    let freq2 = cos(phase * 0.7 + Double(i) * 0.45) * 0.3 + 0.5
                    let response = freq1 * 0.6 + freq2 * 0.4
                    let h = max(2.5, size.height * max(audioLevel, 0.05) * CGFloat(response))
                    let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: 1.5)
                    context.fill(path, with: .color(Color.calmAccent(for: scheme).opacity(0.85)))
                }
            }
        }
    }
}

// MARK: - Compatibility aliases (kept for any remaining call sites)

struct LedgerEntryRow: View {
    let entry: Transcription
    let scheme: ColorScheme
    let onDelete: () -> Void

    var body: some View {
        HistoryRow(entry: entry, scheme: scheme, onDelete: onDelete)
    }
}

struct TranscriptionRow: View {
    let entry: Transcription
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HistoryRow(entry: entry, scheme: scheme, onDelete: onDelete)
    }
}
