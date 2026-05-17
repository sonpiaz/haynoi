import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case history = "History"
    case settings = "Settings"
    case usage = "Usage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .history: return "waveform.circle"
        case .settings: return "gear"
        case .usage: return "chart.bar"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var state: AppState
    @State private var selected: SidebarItem = .history

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selected) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            ZStack {
                switch selected {
                case .history:
                    ContentView()
                        .environmentObject(state)
                case .settings:
                    SettingsView()
                case .usage:
                    UsageView()
                }

                // Recording overlay on top of everything
                if state.showOverlay {
                    recordingOverlay
                }
            }
        }
    }

    private var recordingOverlay: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.28)).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(.ultraThinMaterial).frame(width: 78, height: 78)
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.red)
                }
                Text("Listening…")
                    .font(.headline).fontWeight(.semibold)

                HStack(spacing: 3) {
                    ForEach(0..<12, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(0.9))
                            .frame(width: 4, height: overlayBarHeight(i))
                    }
                }
                .frame(height: 28)
                .animation(.easeInOut(duration: 0.08), value: state.audioLevel)

                Text("Release ⌘ to stop")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .shadow(radius: 18)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func overlayBarHeight(_ i: Int) -> CGFloat {
        let level = CGFloat(max(state.audioLevel, 0.05))
        let variation = sin(Double(i) * 0.75) * 0.28 + 0.72
        return max(6, level * 28 * variation)
    }
}

// MARK: - Usage View (extracted from SettingsView)

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
