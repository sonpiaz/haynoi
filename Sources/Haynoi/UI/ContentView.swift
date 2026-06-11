import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var state: AppState

    // Live hotkey symbol — re-reads when the key changes.
    // @AppStorage so the view re-renders if the setting changes during a session.
    @AppStorage("hotkeyChoice") private var hotkeyChoice = "command"

    // Search field for item 5
    @State private var searchText = ""
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if state.transcriptions.isEmpty {
                emptyState
            } else {
                statsHeader
                Divider()
                if !state.transcriptions.isEmpty {
                    searchField
                    Divider()
                }
                transcriptionList
            }

            Divider()
            statusBar
        }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        HStack(spacing: 16) {
            statBadge(systemImage: "flame.fill",
                      color: .orange,
                      value: "\(UsageTracker.streakDays)",
                      label: "day streak")
            statBadge(systemImage: "text.word.spacing",
                      color: .blue,
                      value: formatWords(UsageTracker.totalWords),
                      label: "words")
            statBadge(systemImage: "gauge.with.needle",
                      color: .green,
                      value: "\(UsageTracker.wordsPerMinute)",
                      label: "WPM")
            Spacer()
            Text("\(UsageTracker.currentMonthCount) this month")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func statBadge(systemImage: String, color: Color, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .font(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(.caption, design: .rounded)).fontWeight(.semibold)
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search transcriptions", text: $searchText)
                .font(.caption)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // Clear history button
            Button {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Transcription List

    private var transcriptionList: some View {
        let filtered = filteredTranscriptions
        return ScrollView {
            if filtered.isEmpty && !searchText.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("No results for \"\(searchText)\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(groupedFiltered(filtered), id: \.key) { group in
                        Text(group.key.uppercased())
                            .font(.system(.caption2, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 2)

                        ForEach(group.value) { entry in
                            TranscriptionRow(entry: entry) {
                                state.deleteTranscription(id: entry.id)
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.vertical, 8)
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("Hold \(HotkeyDisplay.symbolAndName) and speak")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Your transcriptions will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        VStack(spacing: 0) {
            // Transient status message (non-error, item 6)
            if let statusMsg = state.status {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue).font(.caption)
                    Text(statusMsg).font(.caption).foregroundStyle(.blue).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.06))
                Divider()
            }

            HStack(spacing: 8) {
                if state.isRecording {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    levelBars
                    Text(formatDuration(state.recordingDuration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                } else if state.isTranscribing {
                    ProgressView().controlSize(.small)
                    Text("Transcribing...").font(.caption).foregroundStyle(.secondary)
                } else if let error = state.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                } else {
                    Image(systemName: "waveform.circle")
                        .foregroundStyle(.secondary).font(.caption)
                    Text("Hold \(HotkeyDisplay.symbol) to record")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var levelBars: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.red.opacity(0.8))
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .frame(height: 16)
        .animation(.easeInOut(duration: 0.1), value: state.audioLevel)
    }

    // MARK: - Helpers

    private func barHeight(_ i: Int) -> CGFloat {
        let level = CGFloat(state.audioLevel)
        let variation = sin(Double(i) * 0.9) * 0.3 + 0.7
        return max(3, level * 16 * variation)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }

    private func formatWords(_ count: Int) -> String {
        if count >= 1000 { return String(format: "%.1fK", Float(count) / 1000) }
        return "\(count)"
    }
}

// MARK: - Transcription Row

struct TranscriptionRow: View {
    let entry: Transcription
    let onDelete: () -> Void

    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(.body, design: .rounded))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(entry.timestamp, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(entry.wordCount) words")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if isHovered {
                HStack(spacing: 4) {
                    // Copy button
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(copied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")

                    // Delete button
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            onDelete()
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
