import SwiftUI
import Combine

// MARK: - ContentView (Mercury Ledger)

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    @AppStorage("hotkeyChoice") private var hotkeyChoice = "command"
    @State private var searchText = ""
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if state.transcriptions.isEmpty {
                emptyState
            } else {
                greetingBlock
                mercuryLine
                statsStrip
                mercuryLine
                searchBar
                mercuryLine
                ledgerList
            }
            mercuryLine
            ledgerStatusBar
        }
        .background(Color.mercuryBackground(for: scheme))
    }

    // MARK: - Greeting Block

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greetingString)
                .font(.mercuryGreeting)
                .foregroundStyle(Color.mercuryLabel2(for: scheme))

            Group {
                if state.totalWords > 0 {
                    (
                        Text("You have spoken ")
                            .foregroundStyle(Color.mercuryLabel4(for: scheme))
                        + Text("\(formatWords(state.totalWords)) words")
                            .fontWeight(.medium)
                            .foregroundStyle(Color.mercuryLabel3(for: scheme))
                        + Text(" — and counting.")
                            .foregroundStyle(Color.mercuryLabel4(for: scheme))
                    )
                } else {
                    Text("Start dictating and your words will appear here.")
                        .foregroundStyle(Color.mercuryLabel4(for: scheme))
                }
            }
            .font(.mercuryGreetingStat)
        }
        .padding(.horizontal, R.r6)
        .padding(.vertical, R.r5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mercuryBackground(for: scheme))
    }

    // MARK: - Stats Strip

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statItem(value: "\(UsageTracker.streakDays)", label: "day streak", style: .orange)
            statDivider
            statItem(value: formatWords(UsageTracker.totalWords), label: "total words", style: .aurora)
            statDivider

            if UsageTracker.wordsPerMinute > 0 {
                statItem(value: "\(UsageTracker.wordsPerMinute)", label: "avg WPM", style: .ink)
                statDivider
            }

            statItem(value: "\(UsageTracker.currentMonthCount)", label: "this month", style: .ink)
            Spacer()
        }
        .padding(.horizontal, R.r6)
        .frame(height: 60)
        .background(Color.mercuryWarm(for: scheme))
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.mercuryDivider(for: scheme))
            .frame(width: 1, height: 28)
            .padding(.trailing, R.r5)
    }

    private enum StatStyle { case orange, aurora, ink }

    @ViewBuilder
    private func statItem(value: String, label: String, style: StatStyle) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            switch style {
            case .orange:
                Text(value)
                    .font(.mercuryStatValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.mercuryOrange)
            case .aurora:
                Text(value)
                    .font(.mercuryStatValue)
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.auroraBlue, .auroraViolet],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            case .ink:
                Text(value)
                    .font(.mercuryStatValue)
                    .monospacedDigit()
                    .foregroundStyle(Color.mercuryLabel(for: scheme))
            }

            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.mercuryLabel4(for: scheme))
        }
        .padding(.trailing, R.r5)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: R.r2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.mercuryLabel5(for: scheme))

            TextField("Search your ledger…", text: $searchText)
                .font(.system(size: 12))
                .foregroundStyle(Color.mercuryLabel2(for: scheme))
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mercuryLabel5(for: scheme))
                }
                .buttonStyle(.plain)
            }

            Button {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mercuryLabel5(for: scheme))
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
        .padding(.horizontal, R.r6)
        .frame(height: 40)
        .background(Color.mercuryBackground(for: scheme))
    }

    // MARK: - Ledger List

    private var ledgerList: some View {
        let filtered = filteredTranscriptions
        return ScrollView {
            if filtered.isEmpty && !searchText.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.mercuryLabel5(for: scheme))
                    Text("No results for \"\(searchText)\"")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mercuryLabel4(for: scheme))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedFiltered(filtered), id: \.key) { group in
                        // Date group header — small-caps serif
                        HStack(spacing: R.r3) {
                            Text(group.key)
                                .font(.mercuryGroupLabel)
                                .foregroundStyle(Color.mercuryLabel5(for: scheme))
                                .textCase(nil)

                            Rectangle()
                                .fill(Color.mercuryDivider(for: scheme))
                                .frame(height: 1)
                        }
                        .padding(.horizontal, R.r6)
                        .padding(.top, 14)
                        .padding(.bottom, 6)

                        ForEach(group.value) { entry in
                            LedgerEntryRow(entry: entry, scheme: scheme) {
                                state.deleteTranscription(id: entry.id)
                            }
                        }
                    }
                }
                .padding(.bottom, R.r3)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.auroraBlue.opacity(0.06))
                    .frame(width: 72, height: 72)
                Image(systemName: "waveform.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.mercuryLabel5(for: scheme))
            }
            VStack(spacing: 6) {
                Text("Your ledger is empty.")
                    .font(.system(size: 15, design: .serif).italic())
                    .foregroundStyle(Color.mercuryLabel3(for: scheme))
                Text("Hold \(HotkeyDisplay.symbolAndName) and speak — your words appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mercuryLabel4(for: scheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.mercuryBackground(for: scheme))
    }

    // MARK: - Status Bar

    private var ledgerStatusBar: some View {
        VStack(spacing: 0) {
            if let statusMsg = state.status {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.auroraBlue)
                        .font(.system(size: 11))
                    Text(statusMsg)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.auroraBlue)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, R.r6)
                .padding(.vertical, 5)
                .background(Color.auroraBlue.opacity(0.06))
                mercuryLine
            }

            HStack(spacing: R.r2) {
                if state.isRecording {
                    Circle()
                        .fill(Color.mercuryOrange)
                        .frame(width: 6, height: 6)
                    MercuryLevelBars(audioLevel: CGFloat(state.audioLevel))
                        .frame(width: 40, height: 14)
                    Text(formatDuration(state.recordingDuration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.mercuryOrange)
                        .monospacedDigit()
                } else if state.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mercuryLabel4(for: scheme))
                } else if let error = state.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.mercuryOrange)
                        .font(.system(size: 11))
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red)
                        .lineLimit(1)
                } else {
                    Circle()
                        .fill(Color.mercuryLabel5(for: scheme))
                        .frame(width: 6, height: 6)
                    (
                        Text("Hold ")
                        + Text(HotkeyDisplay.symbol)
                        + Text(" to record  ·  Powered by Kyma")
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mercuryLabel4(for: scheme))
                }
                Spacer()
            }
            .padding(.horizontal, R.r6)
            .padding(.vertical, 10)
            .background(Color.mercuryWarm(for: scheme))
        }
    }

    // MARK: - Shared divider

    private var mercuryLine: some View {
        Rectangle()
            .fill(Color.mercuryDivider(for: scheme))
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

    private func groupedFiltered(_ items: [Transcription]) -> [(key: String, value: [Transcription])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: items) { entry -> String in
            if cal.isDateInToday(entry.timestamp) { return "Today" }
            if cal.isDateInYesterday(entry.timestamp) { return "Yesterday" }
            let f = DateFormatter()
            f.dateFormat = "MMMM d, yyyy"
            return f.string(from: entry.timestamp)
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
        HStack(alignment: .top, spacing: R.r4) {
            // Main content
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mercuryLabel2(for: scheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                // Language tag
                let lang = detectLanguage(entry.text)
                Text(lang.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(lang == "vi" ? Color.auroraBlue : Color(hex: "#0F8CA5"))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        lang == "vi"
                            ? Color.auroraBlue.opacity(0.10)
                            : Color.auroraCyan.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
            }

            // Meta column
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.timestamp, style: .time)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mercuryLabel5(for: scheme))
                    .monospacedDigit()

                Text("\(entry.wordCount) words")
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(Color.mercuryLabel4(for: scheme))
                    .monospacedDigit()

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
                                .foregroundStyle(copied ? Color.mercuryGreen : Color.mercuryLabel3(for: scheme))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 26, height: 26)
                        .background(Color.mercuryMid(for: scheme), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mercuryDivider(for: scheme), lineWidth: 1))
                        .help("Copy")

                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { onDelete() }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.mercuryOrange)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 26, height: 26)
                        .background(Color.mercuryMid(for: scheme), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mercuryDivider(for: scheme), lineWidth: 1))
                        .help("Delete")
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.horizontal, R.r6)
        .padding(.vertical, 12)
        .background(isHovered ? Color.mercuryWarm(for: scheme) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.mercuryDivider(for: scheme))
                .frame(height: 1)
                .padding(.leading, R.r6)
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: copied)
        .onHover { isHovered = $0 }
    }

    private func detectLanguage(_ text: String) -> String {
        let viChars = CharacterSet(charactersIn: "àáảãạăắặằẵẳâấậầẫẩđèéẹẻẽêếệềễểìíịỉĩòóọỏõôốộồỗổơớợờỡởùúụủũưứựừữửỳýỵỷỹÀÁẢÃẠĂẮẶẰẴẲÂẤẬẦẪẨĐÈÉẸẺẼÊẾỆỀỄỂÌÍỊỈĨÒÓỌỎÕÔỐỘỒỖỔƠỚỢỜỠỞÙÚỤỦŨƯỨỰỪỮỬỲÝỴỶỸ")
        for char in text.unicodeScalars {
            if viChars.contains(char) { return "vi" }
        }
        return "en"
    }
}

// MARK: - Mercury Level Bars (recording indicator)

struct MercuryLevelBars: View {
    let audioLevel: CGFloat
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
                    context.fill(path, with: .color(Color.mercuryOrange.opacity(0.75)))
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
