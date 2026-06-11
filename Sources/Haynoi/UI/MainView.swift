import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case history = "History"
    case usage = "Usage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .history: return "waveform.circle"
        case .usage: return "chart.bar"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var state: AppState

    // Live-updating hotkey symbol for guidance strings
    @AppStorage("hotkeyChoice") private var hotkeyChoice = "command"

    @State private var selected: SidebarItem = .history

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selected) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
            Divider()
            SettingsLink {
                Label("Settings", systemImage: "gear")
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        } detail: {
            ZStack(alignment: .top) {
                switch selected {
                case .history:
                    ContentView()
                        .environmentObject(state)
                case .usage:
                    UsageView()
                }

                // Item 4: slim non-blocking banner instead of a full-window dim overlay
                if state.isRecording {
                    recordingBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: state.isRecording)
        }
    }

    // MARK: - Recording Banner (Item 4)

    private var recordingBanner: some View {
        HStack(spacing: 10) {
            // Single shared waveform — same visual language as the orb
            RecordingBannerWaveform(audioLevel: CGFloat(state.audioLevel))
                .frame(width: 36, height: 16)

            Text("Recording — release \(HotkeyDisplay.symbol) to transcribe")
                .font(.caption)
                .foregroundStyle(.primary)

            Spacer()

            Text(formatDuration(state.recordingDuration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 0))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

// MARK: - Recording Banner Waveform (Item 4, shared visual language)

/// A simple bar waveform used in the banner — same visual language as the orb
/// ring, but linearized for a horizontal strip.  Zero-dependency on the orb
/// implementation so each can evolve independently.
struct RecordingBannerWaveform: View {
    let audioLevel: CGFloat

    private let barCount = 8

    var body: some View {
        // TimelineView drives the redraw; phase derives from wall-clock time so
        // there is no unbounded animated value losing float precision.
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
                    let h = max(3, size.height * max(audioLevel, 0.05) * CGFloat(response))

                    let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: 1.5)
                    context.fill(path, with: .color(Color(red: 0.35, green: 0.78, blue: 0.98).opacity(0.8)))
                }
            }
        }
    }
}

// MARK: - Usage View

struct UsageView: View {
    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(UsageTracker.currentMonthCount)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                        Text("transcriptions this month")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                }
            }

            Section("History") {
                let stats = UsageTracker.stats
                if stats.isEmpty {
                    Text("No usage data yet").foregroundStyle(.secondary)
                } else {
                    ForEach(stats, id: \.month) { item in
                        HStack {
                            Text(item.month).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text("\(item.count) transcriptions").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
