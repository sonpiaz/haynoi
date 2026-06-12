import SwiftUI
import Combine

// MARK: - ContentView (Calm Ledger)

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    @AppStorage("hotkeyChoice") private var hotkeyChoice = "command"
    @State private var searchText = ""
    @State private var showClearConfirmation = false

    /// Called when the user taps the stats strip (D24 — click-through to Insights).
    var onStatStripTap: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if state.transcriptions.isEmpty {
                emptyState
            } else {
                greetingBlock
                calmLine
                // D24: stat strip is a click-through to the Insights page.
                statsStrip
                    .contentShape(Rectangle())
                    .onTapGesture { onStatStripTap?() }
                    .help("Open Insights")
                calmLine
                searchBar
                calmLine
                ledgerList
            }
            calmLine
            ledgerStatusBar
        }
        .background(Color.calmBackground(for: scheme))
    }

    // MARK: - Greeting Block

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greetingString)
                .font(.calmHeading)
                .foregroundStyle(Color.calmLabel(for: scheme))

            Group {
                if state.totalWords > 0 {
                    (
                        Text("You have spoken ")
                            .foregroundStyle(Color.calmLabel4(for: scheme))
                        + Text("\(formatWords(state.totalWords)) words")
                            .fontWeight(.medium)
                            .foregroundStyle(Color.calmLabel3(for: scheme))
                        + Text(" — and counting.")
                            .foregroundStyle(Color.calmLabel4(for: scheme))
                    )
                } else {
                    Text("Start dictating and your words will appear here.")
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
            }
            .font(.system(size: 13))

            // D15: one-time milestone greeting echo — shown until user opens Insights.
            if MilestoneTracker.hasUnseenMilestone,
               let milestone = MilestoneTracker.latestMilestone(for: UsageTracker.totalWords) {
                milestoneEchoLine(milestone: milestone)
            }
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, C.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.calmBackground(for: scheme))
    }

    // MARK: - Stats Strip

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statItem(value: "\(UsageTracker.streakDays)", label: "day streak", showOrb: false)
            statDivider
            // The aurora orb dot lives only on total words — sanctioned aurora moment.
            statItem(value: formatWords(UsageTracker.totalWords), label: "total words", showOrb: true)
            statDivider

            if UsageTracker.wordsPerMinute > 0 {
                statItem(value: "\(UsageTracker.wordsPerMinute)", label: "avg WPM", showOrb: false)
                statDivider
            }

            statItem(value: "\(UsageTracker.currentMonthCount)", label: "this month", showOrb: false)
            Spacer()
        }
        .padding(.horizontal, C.s6)
        .frame(height: 64)
        .background(Color.calmSubtle(for: scheme))
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.calmDivider(for: scheme))
            .frame(width: 1, height: 28)
            .padding(.trailing, C.s5)
    }

    @ViewBuilder
    private func statItem(value: String, label: String, showOrb: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text(value)
                    .font(.calmStatValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.calmLabel(for: scheme))
                if showOrb {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.calmAuroraCyan, .calmAuroraViolet],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 9, height: 9)
                        .shadow(color: Color.calmAuroraCyan.opacity(0.4), radius: 3)
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.calmLabel4(for: scheme))
        }
        .padding(.trailing, C.s5)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: C.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.calmLabel4(for: scheme))

            TextField("Search your ledger…", text: $searchText)
                .font(.system(size: 12))
                .foregroundStyle(Color.calmLabel(for: scheme))
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
                .buttonStyle(.plain)
            }

            Button {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
            .buttonStyle(.plain)
            .help("Clear History")
            .confirmationDialog(
                "Clear all transcription history?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    state.clearAllTranscriptions()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(.horizontal, C.s6)
        .frame(height: 42)
        .background(Color.calmBackground(for: scheme))
    }

    // MARK: - Ledger List

    private var ledgerList: some View {
        let filtered = filteredTranscriptions
        return ScrollView {
            if filtered.isEmpty && !searchText.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                    Text("No results for \"\(searchText)\"")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedFiltered(filtered), id: \.key) { group in
                        // Date group header — quiet uppercase calm label
                        HStack(spacing: C.s3) {
                            Text(group.key.uppercased())
                                .font(.calmSectionLabel)
                                .kerning(0.7)
                                .foregroundStyle(Color.calmLabel4(for: scheme))

                            Rectangle()
                                .fill(Color.calmDivider(for: scheme))
                                .frame(height: 1)
                        }
                        .padding(.horizontal, C.s6)
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                        ForEach(group.value) { entry in
                            LedgerEntryRow(entry: entry, scheme: scheme) {
                                state.deleteTranscription(id: entry.id)
                            }
                        }
                    }
                }
                .padding(.bottom, C.s3)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.calmAccentWash(for: scheme))
                    .frame(width: 72, height: 72)
                Image(systemName: "waveform.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.calmAccent(for: scheme))
            }
            VStack(spacing: 6) {
                Text("Your ledger is empty.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.calmLabel(for: scheme))
                Text("Hold \(HotkeyDisplay.symbolAndName) and speak — your words appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.calmBackground(for: scheme))
    }

    // MARK: - Status Bar

    private var ledgerStatusBar: some View {
        VStack(spacing: 0) {
            if let statusMsg = state.status {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.calmAccent(for: scheme))
                        .font(.system(size: 11))
                    Text(statusMsg)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmAccent(for: scheme))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, C.s6)
                .padding(.vertical, 5)
                .background(Color.calmAccentWash(for: scheme))
                calmLine
            }

            HStack(spacing: C.s2) {
                if state.isRecording {
                    CalmStatusDot(status: .recording)
                    CalmLevelBars(audioLevel: CGFloat(state.audioLevel), scheme: scheme)
                        .frame(width: 40, height: 14)
                    Text(formatDuration(state.recordingDuration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.calmAccent(for: scheme))
                        .monospacedDigit()
                } else if state.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel3(for: scheme))
                } else if let error = state.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.calmWarn)
                        .font(.system(size: 11))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmWarn)
                        .lineLimit(1)
                } else {
                    CalmStatusDot(status: .idle)
                    (
                        Text("Hold ")
                        + Text(HotkeyDisplay.symbol)
                        + Text(" to record  ·  Powered by Kyma")
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                }
                Spacer()
            }
            .padding(.horizontal, C.s6)
            .padding(.vertical, 10)
            .background(Color.calmSubtle(for: scheme))
        }
    }

    // MARK: - Milestone Echo (D15)

    private func milestoneEchoLine(milestone: MilestoneTracker.Milestone) -> some View {
        let isVi = resolveIsVi()
        let total = UsageTracker.totalWords
        let label = milestoneComparisonLabel(total: total, isVi: isVi)
        let msg = isVi
            ? "Bạn đã đạt \(formatWords(milestone.threshold)) từ — \(label)."
            : "You've reached \(formatWords(milestone.threshold)) words — \(label)."
        return Text(msg)
            .font(.system(size: 12))
            .foregroundStyle(Color.calmAccent(for: scheme))
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { MilestoneTracker.clearUnseenFlag() }
    }

    private func milestoneComparisonLabel(total: Int, isVi: Bool) -> String {
        switch total {
        case 1_000_000...: return isVi ? "một kệ sách" : "a library shelf"
        case 500_000...:   return isVi ? "một tập bách khoa toàn thư" : "an encyclopedia volume"
        case 250_000...:   return isVi ? "một bộ ba tiểu thuyết" : "a boxed trilogy"
        case 100_000...:   return isVi ? "hai tiểu thuyết" : "two novels"
        case 50_000...:    return isVi ? "một tiểu thuyết" : "a novel"
        case 25_000...:    return isVi ? "một truyện vừa" : "a novella"
        default:           return isVi ? "một truyện ngắn" : "a short story"
        }
    }

    private func resolveIsVi() -> Bool {
        let hint = UserDefaults.standard.string(forKey: "languageHint") ?? "auto"
        if hint == "vi" { return true }
        if hint == "en" { return false }
        return Locale.current.language.languageCode?.identifier == "vi"
    }

    // MARK: - Shared divider

    private var calmLine: some View {
        Rectangle()
            .fill(Color.calmDivider(for: scheme))
            .frame(height: 1)
    }

    // MARK: - Helpers

    private var greetingString: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let langHint = UserDefaults.standard.string(forKey: "languageHint") ?? "auto"
        let isVi: Bool
        if langHint == "vi" {
            isVi = true
        } else if langHint == "en" {
            isVi = false
        } else {
            isVi = Locale.current.language.languageCode?.identifier == "vi"
        }
        if isVi {
            switch hour {
            case 0..<12:  return "Chào buổi sáng."
            case 12..<18: return "Chào buổi chiều."
            default:      return "Chào buổi tối."
            }
        } else {
            switch hour {
            case 0..<12:  return "Good morning."
            case 12..<18: return "Good afternoon."
            default:      return "Good evening."
            }
        }
    }

    private var filteredTranscriptions: [Transcription] {
        guard !searchText.isEmpty else { return state.transcriptions }
        let q = searchText.lowercased()
        return state.transcriptions.filter { $0.text.lowercased().contains(q) }
    }

    private static let groupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()

    private func groupedFiltered(_ items: [Transcription]) -> [(key: String, value: [Transcription])] {
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

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

// MARK: - Ledger Entry Row

struct LedgerEntryRow: View {
    let entry: Transcription
    let scheme: ColorScheme
    let onDelete: () -> Void

    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: C.s3) {
            // Language tag — leading, mirrors the board's row layout
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

            // Main content
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.calmLabel(for: scheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Text("\(timeString)  ·  \(entry.wordCount) words")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .monospacedDigit()
            }

            // Hover actions
            if isHovered {
                HStack(spacing: 5) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(copied ? Color.calmSuccess : Color.calmLabel3(for: scheme))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 26, height: 26)
                    .background(Color.calmSubtle(for: scheme), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.calmHairline(for: scheme), lineWidth: 1))
                    .help("Copy")

                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { onDelete() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.calmWarn)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 26, height: 26)
                    .background(Color.calmSubtle(for: scheme), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.calmHairline(for: scheme), lineWidth: 1))
                    .help("Delete")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, 13)
        .background(isHovered ? Color.calmHover(for: scheme) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.calmDivider(for: scheme))
                .frame(height: 1)
                .padding(.leading, C.s6)
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: copied)
        .onHover { isHovered = $0 }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: entry.timestamp)
    }

    private func detectLanguage(_ text: String) -> String {
        let viChars = CharacterSet(charactersIn: "àáảãạăắặằẵẳâấậầẫẩđèéẹẻẽêếệềễểìíịỉĩòóọỏõôốộồỗổơớợờỡởùúụủũưứựừữửỳýỵỷỹÀÁẢÃẠĂẮẶẰẴẲÂẤẬẦẪẨĐÈÉẸẺẼÊẾỆỀỄỂÌÍỊỈĨÒÓỌỎÕÔỐỘỒỖỔƠỚỢỜỠỞÙÚỤỦŨƯỨỰỪỮỬỲÝỴỶỸ")
        for char in text.unicodeScalars {
            if viChars.contains(char) { return "vi" }
        }
        return "en"
    }
}

// MARK: - Calm Level Bars (recording indicator)

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

// MARK: - TranscriptionRow (compatibility alias — not used in Mercury flow)

struct TranscriptionRow: View {
    let entry: Transcription
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LedgerEntryRow(entry: entry, scheme: scheme, onDelete: onDelete)
    }
}
