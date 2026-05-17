import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if state.transcriptions.isEmpty {
                emptyState
            } else {
                statsHeader
                Divider()
                transcriptionList
            }

            Divider()
            statusBar
        }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        HStack(spacing: 16) {
            statBadge(icon: "⭐", value: "\(UsageTracker.streakDays)", label: "day streak")
            statBadge(icon: "🚀", value: formatWords(UsageTracker.totalWords), label: "words")
            statBadge(icon: "🏆", value: "\(UsageTracker.wordsPerMinute)", label: "WPM")
            Spacer()
            Text("\(UsageTracker.currentMonthCount) this month")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func statBadge(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Text(icon)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(.caption, design: .rounded)).fontWeight(.semibold)
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transcription List (grouped by date)

    private var transcriptionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(state.groupedByDate, id: \.key) { group in
                    Text(group.key.uppercased())
                        .font(.system(.caption2, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 2)

                    ForEach(group.value) { entry in
                        TranscriptionRow(entry: entry)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("Hold ⌘ Command and speak")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Your transcriptions will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
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
                Text("Hold ⌘ to record").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, style: .time)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)

            Text(entry.text)
                .font(.system(.body, design: .rounded))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
    }
}
