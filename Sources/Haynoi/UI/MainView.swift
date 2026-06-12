import SwiftUI

// MARK: - MainView (board "01 — MAIN WINDOW")
//
// Faithful rebuild of the founder-approved board:
//   LEFT SIDEBAR (~210pt): app icon + "Haynoi" wordmark → nav rows
//     (History / Recent / Modes / About) → bottom Settings row + account chip.
//   MAIN CONTENT: a slim optional recording banner, then the page selected in
//     the sidebar:
//       History → top 4-card stat row (Day streak / Words / Avg WPM / HOLD TO
//                 RECORD keycaps) + grouped history list with section headers.
//       Recent  → the same list, limited to the most recent entries.
//       Modes   → the transcription-mode chips.
//       About   → app / version / Powered-by-Kyma card.
//
// Light white-gray Calm palette throughout; quiet hairlines do the structural
// work. Engine wiring (AppState / BalanceManager / UsageTracker) unchanged.

enum SidebarSection: String, CaseIterable, Identifiable {
    case history  = "History"
    case insights = "Insights"
    case recent   = "Recent"
    case modes    = "Modes"
    case about    = "About"

    var id: String { rawValue }

    /// SF Symbol mirroring the board's nav glyphs.
    var icon: String {
        switch self {
        case .history:  return "list.bullet"
        case .insights: return "chart.bar"
        case .recent:   return "clock"
        case .modes:    return "lightbulb"
        case .about:    return "info.circle"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var balanceManager = BalanceManager.shared
    @ObservedObject private var authState = AuthState.shared

    @State private var section: SidebarSection = .history

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)

            // Hairline divider sidebar → content
            Rectangle()
                .fill(Color.calmDivider(for: scheme))
                .frame(width: 1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(Color.calmBackground(for: scheme))
        .onAppear { BalanceManager.shared.refresh() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App icon + wordmark
            HStack(spacing: 9) {
                AppIconBadge(size: 28)
                Text("Haynoi")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.calmLabel(for: scheme))
                    .kerning(-0.2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Rectangle()
                .fill(Color.calmDivider(for: scheme))
                .frame(height: 1)
                .padding(.horizontal, 0)

            // Nav rows
            VStack(spacing: 1) {
                ForEach(SidebarSection.allCases) { item in
                    navRow(item)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.calmDivider(for: scheme))
                .frame(height: 1)

            // Bottom: Settings + account chip
            VStack(alignment: .leading, spacing: 0) {
                SettingsLink {
                    HStack(spacing: 9) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.calmLabel4(for: scheme))
                            .frame(width: 15)
                        Text("Settings")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.calmLabel3(for: scheme))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowButtonStyle(scheme: scheme))

                accountChip
                    .padding(.top, 4)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(Color.calmSubtle(for: scheme))
    }

    @ViewBuilder
    private func navRow(_ item: SidebarSection) -> some View {
        let isActive = section == item
        Button {
            section = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Color.calmAccent(for: scheme) : Color.calmLabel4(for: scheme))
                    .frame(width: 15)
                Text(item.rawValue)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.calmAccent(for: scheme) : Color.calmLabel3(for: scheme))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isActive ? Color.calmActive(for: scheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accountChip: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.calmAuroraCyan, .calmAuroraViolet],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                Text(avatarInitial)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(accountName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.calmLabel(for: scheme))
                    .lineLimit(1)
                Text(balanceLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var avatarInitial: String {
        if let email = authState.signedInEmail, let f = email.first {
            return String(f).uppercased()
        }
        return "H"
    }

    private var accountName: String {
        if let email = authState.signedInEmail {
            let user = email.split(separator: "@").first.map(String.init) ?? email
            return user.replacingOccurrences(of: ".", with: " ").capitalized
        }
        return "Sign in"
    }

    private var balanceLine: String {
        if let b = balanceManager.balance {
            return String(format: "$%.2f remaining", b)
        }
        return "Pay as you go"
    }

    // MARK: - Content (switches on sidebar section)

    private var content: some View {
        VStack(spacing: 0) {
            if state.isRecording {
                recordingBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                switch section {
                case .history:
                    ContentView(mode: .history)
                        .environmentObject(state)
                case .insights:
                    InsightsView()
                        .environmentObject(state)
                case .recent:
                    ContentView(mode: .recent)
                        .environmentObject(state)
                case .modes:
                    ModesPage()
                case .about:
                    AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.calmBackground(for: scheme))
        .animation(.easeInOut(duration: 0.2), value: state.isRecording)
    }

    // MARK: - Recording Banner (Calm)

    private var recordingBanner: some View {
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

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

// MARK: - Sidebar row button hover style

private struct SidebarRowButtonStyle: ButtonStyle {
    let scheme: ColorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.calmHover(for: scheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
    }
}

// MARK: - App Icon Badge
//
// Renders the bundled app icon if present, otherwise a calm aurora glyph tile so
// the wordmark never sits next to an empty square in previews / fresh installs.

struct AppIconBadge: View {
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let nsImage = NSImage(named: "AppIcon") {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(LinearGradient(
                        colors: [Color(hex: "#0F1220"), Color(hex: "#1A1E34")],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(LinearGradient.calmAurora)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Modes Page (sidebar → Modes)

private struct ModesPage: View {
    @AppStorage("transcriptionMode") private var modeRaw = TranscriptionMode.normal.rawValue
    @Environment(\.colorScheme) private var scheme

    private var currentMode: TranscriptionMode {
        TranscriptionMode(rawValue: modeRaw) ?? .normal
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Transcription modes")
                    .font(.calmHeading)
                    .foregroundStyle(Color.calmLabel(for: scheme))
                Text("Choose how Haynoi shapes your dictation. The active mode applies everywhere.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .padding(.top, 4)

                VStack(spacing: 10) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        modeCard(mode)
                    }
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(Color.calmBackground(for: scheme))
    }

    @ViewBuilder
    private func modeCard(_ mode: TranscriptionMode) -> some View {
        let isActive = mode == currentMode
        Button {
            modeRaw = mode.rawValue
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isActive ? Color.calmAccentWash(for: scheme) : Color.calmSubtle(for: scheme))
                        .frame(width: 36, height: 36)
                    Image(systemName: mode.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(isActive ? Color.calmAccent(for: scheme) : Color.calmLabel3(for: scheme))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.calmLabel(for: scheme))
                    Text(mode.shortDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.calmLabel4(for: scheme))
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.calmAccent(for: scheme))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(isActive ? Color.calmActive(for: scheme) : Color.calmSurface(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isActive ? Color.calmAccent(for: scheme).opacity(0.4) : Color.calmBorder,
                        lineWidth: isActive ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - About Page (sidebar → About)

private struct AboutPage: View {
    @Environment(\.colorScheme) private var scheme

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    AppIconBadge(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Haynoi")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.calmLabel(for: scheme))
                            .kerning(-0.3)
                        Text("hãy nói · hay nói · Hà Nội")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.calmLabel4(for: scheme))
                            .kerning(0.4)
                    }
                    Spacer()
                }

                VStack(spacing: 0) {
                    aboutRow("Edition", value: versionString)
                    aboutDivider
                    aboutRow("Transcription", value: "Powered by Kyma")
                    aboutDivider
                    aboutLinkRow("Website", url: "https://haynoi.com")
                    aboutDivider
                    aboutLinkRow("Source", url: "https://github.com/sonpiaz/haynoi")
                    aboutDivider
                    aboutLinkRow("Top up credits", url: "https://kymaapi.com")
                }
                .background(Color.calmSurface(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.calmBorder, lineWidth: 1))
                .padding(.top, 24)

                Text("Hold left ⌥ and speak. Your words appear in any app, instantly.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .padding(.top, 16)

                Text("Open source under the MIT license · © 2026 Affitor LLC")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.calmLabel4(for: scheme))
                    .padding(.top, 4)
            }
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
        }
        .background(Color.calmBackground(for: scheme))
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.calmLabel3(for: scheme))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Color.calmLabel(for: scheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func aboutLinkRow(_ label: String, url: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.calmLabel3(for: scheme))
            Spacer()
            Link(destination: URL(string: url) ?? URL(string: "https://haynoi.com")!) {
                HStack(spacing: 3) {
                    Text(url.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.calmAccent(for: scheme))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var aboutDivider: some View {
        Rectangle()
            .fill(Color.calmDivider(for: scheme))
            .frame(height: 1)
            .padding(.leading, 14)
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

// MARK: - UsageView (Calm reskin — retained for Insights / compatibility)

struct UsageView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
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
