import SwiftUI

// MARK: - MainView (Calm "ledger")
//
// Layout: optional recording banner → two-column body
//   Left (flexible): greeting block + stats row + search + ledger history
//   Right (260px): balance card + mode pills + quick nav + settings
// Calm has no aurora top-edge; quiet hairline dividers do the structural work.

struct MainView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme

    @AppStorage("hotkeyChoice") private var hotkeyChoice = "command"

    @ObservedObject private var balanceManager = BalanceManager.shared

    // Context panel nav selection
    @State private var selectedNav: MercuryNavItem = .ledger

    var body: some View {
        VStack(spacing: 0) {
            // Recording banner — slim, calm-styled
            if state.isRecording {
                calmRecordingBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Two-column body
            HStack(spacing: 0) {
                // Left: ledger or insights depending on nav selection
                Group {
                    if selectedNav == .insights {
                        InsightsView()
                            .environmentObject(state)
                    } else {
                        ContentView(onStatStripTap: { selectedNav = .insights })
                            .environmentObject(state)
                    }
                }
                .frame(maxWidth: .infinity)

                // Vertical divider
                Rectangle()
                    .fill(Color.calmDivider(for: scheme))
                    .frame(width: 1)

                // Right: context panel
                contextPanel
                    .frame(width: 260)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Color.calmBackground(for: scheme))
        .animation(.easeInOut(duration: 0.2), value: state.isRecording)
        .onAppear { BalanceManager.shared.refresh() }
    }

    // MARK: - Recording Banner (Calm style)

    private var calmRecordingBanner: some View {
        HStack(spacing: 10) {
            CalmStatusDot(status: .recording)

            RecordingBannerWaveform(audioLevel: CGFloat(state.audioLevel), scheme: scheme)
                .frame(width: 36, height: 14)

            Text("Recording — release \(HotkeyDisplay.symbol) to transcribe")
                .font(.system(size: 12))
                .foregroundStyle(Color.calmLabel3(for: scheme))

            Spacer()

            Text(formatDuration(state.recordingDuration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.calmLabel4(for: scheme))
                .monospacedDigit()
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, 9)
        .background(Color.calmAccentWash(for: scheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.calmDivider(for: scheme))
                .frame(height: 1)
        }
    }

    // MARK: - Context Panel (right rail)

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Balance card
            contextSection(label: "Balance") {
                balanceCard
            }

            contextLine

            // Mode pills
            contextSection(label: "Mode") {
                CalmModePills()
            }

            contextLine

            // Nav links — Ledger and Insights are wired; others are placeholders.
            VStack(alignment: .leading, spacing: 2) {
                calmNavRow(.ledger)
                calmNavRow(.insights)
            }
            .padding(.horizontal, C.s3)
            .padding(.vertical, C.s3)

            Spacer()

            contextLine

            // Settings link
            SettingsLink {
                HStack(spacing: 6) {
                    Image(systemName: "gear")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                    Text("Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
                .padding(.horizontal, C.s5)
                .padding(.vertical, C.s3)
            }
            .buttonStyle(.plain)
        }
        .background(Color.calmSubtle(for: scheme))
    }

    private func contextSection<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: C.s3) {
            Text(label.uppercased())
                .font(.calmSectionLabel)
                .foregroundStyle(Color.calmLabel4(for: scheme))
                .kerning(0.8)
                .padding(.horizontal, C.s5)
                .padding(.top, C.s5)

            content()
                .padding(.horizontal, C.s5)
                .padding(.bottom, C.s5)
        }
    }

    private var contextLine: some View {
        Rectangle()
            .fill(Color.calmDivider(for: scheme))
            .frame(height: 1)
    }

    // MARK: - Balance Card

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let balance = balanceManager.balance {
                Text(String(format: "$%.2f", balance))
                    .font(.calmBalance)
                    .foregroundStyle(Color.calmLabel(for: scheme))
                    .monospacedDigit()

                Text(balance < 0.05
                     ? "Out of credits — top up to continue."
                     : "Pay as you go — no subscription.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .fixedSize(horizontal: false, vertical: true)

                // Aurora balance bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.calmHairline(for: scheme))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient.calmAuroraBar)
                            .frame(width: geo.size.width * balanceFraction, height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.top, 5)
                .padding(.bottom, 2)

                HStack {
                    Text("~$0.02 / min")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                    Spacer()
                    Link("Top up ↗", destination: URL(string: "https://kymaapi.com")!)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.calmAccent(for: scheme))
                }
            } else {
                // Loading / signed out state
                HStack(spacing: 6) {
                    Text("Sign in to see balance.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                    Spacer()
                    SettingsLink {
                        Text("Sign in")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.calmAccent(for: scheme))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(C.s4)
        .background(Color.calmSurface(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.calmBorder, lineWidth: 1)
        )
    }

    private var balanceFraction: CGFloat {
        guard let b = balanceManager.balance, b > 0 else { return 0 }
        // Treat $20 as "full"; cap at 1.0
        return min(CGFloat(b) / 20.0, 1.0)
    }

    // MARK: - Nav Rows

    @ViewBuilder
    private func calmNavRow(_ item: MercuryNavItem) -> some View {
        let isActive = selectedNav == item
        Button {
            selectedNav = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color.calmAccent(for: scheme) : Color.calmLabel4(for: scheme))
                    .frame(width: 16)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.calmAccent(for: scheme) : Color.calmLabel3(for: scheme))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isActive ? Color.calmActive(for: scheme) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

// MARK: - Mercury Nav Items

enum MercuryNavItem: String, CaseIterable, Identifiable {
    case ledger = "Ledger"
    case insights = "Insights"
    case dictionary = "Dictionary"
    case snippets = "Snippets"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ledger:     return "list.bullet.rectangle"
        case .insights:   return "chart.bar"
        case .dictionary: return "book.closed"
        case .snippets:   return "text.quote"
        }
    }
}

// MARK: - Calm Mode Pills

private struct CalmModePills: View {
    @AppStorage("transcriptionMode") private var modeRaw = TranscriptionMode.normal.rawValue
    @Environment(\.colorScheme) private var scheme

    private var currentMode: TranscriptionMode {
        TranscriptionMode(rawValue: modeRaw) ?? .normal
    }

    var body: some View {
        let modes = TranscriptionMode.allCases
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(modes) { mode in
                modePill(mode)
            }
        }
    }

    @ViewBuilder
    private func modePill(_ mode: TranscriptionMode) -> some View {
        let isActive = mode == currentMode
        Button {
            modeRaw = mode.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? Color.calmAccent(for: scheme) : Color.calmLabel2(for: scheme))
                Text(mode.shortDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isActive ? Color.calmActive(for: scheme) : Color.calmSurface(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isActive ? Color.calmAccent(for: scheme).opacity(0.6) : Color.calmBorder,
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recording Banner Waveform (calm accent-toned)

struct RecordingBannerWaveform: View {
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
                    let h = max(3, size.height * max(audioLevel, 0.05) * CGFloat(response))
                    let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
                    let path = Path(roundedRect: rect, cornerRadius: 1.5)
                    context.fill(path, with: .color(Color.calmAccent(for: scheme).opacity(0.85)))
                }
            }
        }
    }
}

// MARK: - UsageView (Calm reskin)

struct UsageView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            // Stat
            VStack(alignment: .leading, spacing: 4) {
                Text("\(UsageTracker.currentMonthCount)")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(Color.calmLabel(for: scheme))
                    .monospacedDigit()
                Text("transcriptions this month")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(C.s6)
            .background(Color.calmSubtle(for: scheme))

            Rectangle()
                .fill(Color.calmDivider(for: scheme))
                .frame(height: 1)

            // Monthly breakdown
            let stats = UsageTracker.stats
            if stats.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text("No usage history yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(stats, id: \.month) { item in
                            HStack {
                                Text(item.month)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Color.calmLabel3(for: scheme))
                                Spacer()
                                Text("\(item.count) transcriptions")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.calmLabel4(for: scheme))
                            }
                            .padding(.horizontal, C.s6)
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.calmDivider(for: scheme))
                                    .frame(height: 1)
                                    .padding(.leading, C.s6)
                            }
                        }
                    }
                }
            }
        }
        .background(Color.calmBackground(for: scheme))
    }
}
