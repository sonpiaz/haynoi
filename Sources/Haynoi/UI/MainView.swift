import SwiftUI

// MARK: - MainView (Obsidian Instrument · Light-primary)
//
// Restyled to the "light-b-paper-v2" approved mockup:
//   LEFT SIDEBAR (~210pt): obsidian stone + "Haynoi" wordmark → nav rows with
//     3pt Signal-Cyan active-edge indicator → Settings + account chip.
//   MAIN CONTENT: optional recording banner, then the selected page:
//       History → ContentView(mode: .history)
//       Insights → InsightsView
//       Modes   → ModesPage
//       About   → AboutPage
//
// All colours come from ObsidianTokens. No hex literals in this file.
// Engine wiring (AppState / BalanceManager / UsageTracker) unchanged.

enum SidebarSection: String, CaseIterable, Identifiable {
    case history  = "History"
    case insights = "Insights"
    case modes    = "Modes"
    case about    = "About"

    var id: String { rawValue }

    /// SF Symbol mirroring the board's nav glyphs.
    var icon: String {
        switch self {
        case .history:  return "list.bullet"
        case .insights: return "chart.bar"
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

            // 1px hairline divider
            Rectangle()
                .fill(Color.obsidianDivider(for: scheme))
                .frame(width: 1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(Color.obsidianBackground(for: scheme))
        .onAppear { BalanceManager.shared.refresh() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Obsidian stone + wordmark
            HStack(spacing: 9) {
                AppIconBadge(size: 26)
                Text("Haynoi")
                    .font(.obsidianHeading)
                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                    .kerning(-0.2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, C.s4)
            .padding(.top, C.s3)
            .padding(.bottom, C.s4)

            Rectangle()
                .fill(Color.obsidianDivider(for: scheme))
                .frame(height: 1)

            // Section header
            Text("Navigation")
                .font(.obsidianLabel)
                .foregroundStyle(Color.obsidianLabel4(for: scheme))
                .textCase(.uppercase)
                .tracking(1.0)
                .padding(.horizontal, C.s4)
                .padding(.top, C.s3)
                .padding(.bottom, C.s1)

            // Nav rows
            VStack(spacing: 1) {
                ForEach(SidebarSection.allCases) { item in
                    navRow(item)
                }
            }
            .padding(.horizontal, C.s2)

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.obsidianDivider(for: scheme))
                .frame(height: 1)

            // Bottom: Settings + account chip
            VStack(alignment: .leading, spacing: 0) {
                SettingsLink {
                    HStack(spacing: 9) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.obsidianLabel4(for: scheme))
                            .frame(width: 15)
                        Text("Settings")
                            .font(.obsidianBody)
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowButtonStyle(scheme: scheme))

                SettingsLink {
                    accountChip
                        .contentShape(Rectangle())
                }
                .buttonStyle(SidebarRowButtonStyle(scheme: scheme))
                .padding(.top, 4)
            }
            .padding(.horizontal, C.s2)
            .padding(.top, C.s2)
            .padding(.bottom, 10)
        }
        .background(Color.obsidianSubtle(for: scheme))
    }

    @ViewBuilder
    private func navRow(_ item: SidebarSection) -> some View {
        let isActive = section == item
        Button {
            section = item
        } label: {
            HStack(spacing: 0) {
                // 3pt active-edge accent bar (mockup spec)
                Rectangle()
                    .fill(isActive ? Color.accent : Color.clear)
                    .frame(width: 3, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.trailing, 6)

                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Color.obsidianAccent(for: scheme) : Color.obsidianLabel4(for: scheme))
                    .frame(width: 15)
                    .padding(.trailing, 9)

                Text(item.rawValue)
                    .font(isActive
                          ? Font.custom("BeVietnamPro-Medium", size: 13)
                          : Font.custom("BeVietnamPro-Regular", size: 13))
                    .foregroundStyle(isActive
                                     ? Color.obsidianLabel(for: scheme)
                                     : Color.obsidianLabel3(for: scheme))
                Spacer()
            }
            .padding(.leading, 0)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(
                isActive
                    ? Color.accent.opacity(0.07)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: C.rSM)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accountChip: some View {
        HStack(spacing: 9) {
            // Avatar — Signal Cyan tint circle with accentOnLight initial
            ZStack {
                Circle()
                    .fill(Color.accent.opacity(0.12))
                    .overlay(Circle().strokeBorder(Color.accent.opacity(0.35), lineWidth: 1))
                    .frame(width: 24, height: 24)
                Text(avatarInitial)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentOnLight)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(accountName)
                    .font(Font.custom("BeVietnamPro-Medium", size: 12))
                    .foregroundStyle(Color.obsidianLabel2(for: scheme))
                    .lineLimit(1)
                Text(balanceLine)
                    .font(.obsidianMonoSM)
                    .foregroundStyle(Color.obsidianLabel4(for: scheme))
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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
        switch balanceManager.tier {
        case "pro": return "Pro — unlimited"
        case "max": return "Max — unlimited"
        case "free":
            if let remaining = balanceManager.wordsRemaining {
                return "\(remaining) words left this week"
            }
            return "Free — 2,000 words / week"
        default:
            return "Sign in"
        }
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
                case .modes:
                    ModesPage()
                case .about:
                    AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.obsidianBackground(for: scheme))
        .animation(.obsidianFade, value: state.isRecording)
    }

    // MARK: - Recording Banner

    private var recordingBanner: some View {
        HStack(spacing: 10) {
            CalmStatusDot(status: .recording)

            RecordingBannerWaveform(audioLevel: CGFloat(state.audioLevel), scheme: scheme)
                .frame(width: 36, height: 14)

            Text("Recording — release \(HotkeyDisplay.symbol) to transcribe")
                .font(.obsidianCaption)
                .foregroundStyle(Color.obsidianLabel3(for: scheme))

            Spacer()

            Text(formatDuration(state.recordingDuration))
                .font(.obsidianMonoSM)
                .foregroundStyle(Color.obsidianLabel4(for: scheme))
                .monospacedDigit()
        }
        .padding(.horizontal, C.s6)
        .padding(.vertical, 9)
        .background(Color.obsidianAccentWash(for: scheme))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.obsidianDivider(for: scheme))
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
                configuration.isPressed ? Color.obsidianHover(for: scheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: C.rSM)
            )
    }
}

// MARK: - App Icon Badge
//
// Renders the bundled app icon if present; otherwise an obsidian stone tile
// (dark gradient + Signal Cyan dấu-sắc crescent) so the wordmark never
// sits next to an empty square.

struct AppIconBadge: View {
    var size: CGFloat = 26
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let nsImage = NSImage(named: "AppIcon") {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.27))
        } else {
            // Obsidian stone fallback — always dark, matches the brand
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.27)
                    .fill(LinearGradient(
                        colors: [Color.orbBodyTop, Color.orbBodyBottom],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                // Inner top-edge highlight
                RoundedRectangle(cornerRadius: size * 0.27)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                // dấu-sắc crescent stroke
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.accent, .accentDeep],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: size * 0.42, height: size * 0.09)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .rotationEffect(.degrees(-62))
                    .offset(x: -size * 0.08, y: -size * 0.14)
                    .blur(radius: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: Color.black.opacity(0.28), radius: 3, y: 1)
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
                    .font(.obsidianTitle)
                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                Text("Choose how Haynoi shapes your dictation. The active mode applies everywhere.")
                    .font(.obsidianBody)
                    .foregroundStyle(Color.obsidianLabel4(for: scheme))
                    .lineSpacing(3)
                    .padding(.top, 4)

                VStack(spacing: C.s2) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        modeCard(mode)
                    }
                }
                .padding(.top, C.s5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, C.s6)
            .padding(.vertical, C.s5)
        }
        .background(Color.obsidianBackground(for: scheme))
    }

    @ViewBuilder
    private func modeCard(_ mode: TranscriptionMode) -> some View {
        let isActive = mode == currentMode
        Button {
            modeRaw = mode.rawValue
        } label: {
            HStack(spacing: C.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: ObsidianRadius.sm.rawValue)
                        .fill(isActive
                              ? Color.obsidianAccentWash(for: scheme)
                              : Color.obsidianSubtle(for: scheme))
                        .frame(width: 36, height: 36)
                    Image(systemName: mode.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(isActive
                                         ? Color.obsidianAccent(for: scheme)
                                         : Color.obsidianLabel3(for: scheme))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue)
                        .font(Font.custom("BeVietnamPro-Medium", size: 13))
                        .foregroundStyle(Color.obsidianLabel(for: scheme))
                    Text(mode.shortDescription)
                        .font(.obsidianCaption)
                        .foregroundStyle(Color.obsidianLabel4(for: scheme))
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.obsidianAccent(for: scheme))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                isActive
                    ? Color.accent.opacity(0.06)
                    : Color.obsidianSurface(for: scheme)
            )
            .clipShape(RoundedRectangle(cornerRadius: ObsidianRadius.md.rawValue))
            .overlay(
                RoundedRectangle(cornerRadius: ObsidianRadius.md.rawValue)
                    .stroke(
                        isActive
                            ? Color.accentOnLight.opacity(0.40)
                            : Color.hairlineSolid,
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
                            .font(.obsidianDisplay)
                            .foregroundStyle(Color.obsidianLabel(for: scheme))
                            .kerning(-0.3)
                        Text("hãy nói · hay nói · Hà Nội")
                            .font(.obsidianCaption)
                            .foregroundStyle(Color.obsidianLabel4(for: scheme))
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
                    aboutRow("Pro", value: "Coming soon")
                }
                .background(Color.obsidianSurface(for: scheme))
                .clipShape(RoundedRectangle(cornerRadius: ObsidianRadius.md.rawValue))
                .overlay(
                    RoundedRectangle(cornerRadius: ObsidianRadius.md.rawValue)
                        .stroke(Color.hairlineSolid, lineWidth: 1)
                )
                .padding(.top, C.s5)

                Text("Hold left ⌥ and speak. Your words appear in any app, instantly.")
                    .font(.obsidianCaption)
                    .foregroundStyle(Color.obsidianLabel4(for: scheme))
                    .lineSpacing(2)
                    .padding(.top, C.s4)

                Text("Open source under the MIT license · © 2026 Affitor LLC")
                    .font(.obsidianLabel)
                    .foregroundStyle(Color.obsidianLabel4(for: scheme))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, C.s6)
            .padding(.vertical, C.s6)
        }
        .background(Color.obsidianBackground(for: scheme))
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.obsidianBody)
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
            Spacer()
            Text(value)
                .font(.obsidianBody)
                .foregroundStyle(Color.obsidianLabel(for: scheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, C.s3)
    }

    private func aboutLinkRow(_ label: String, url: String) -> some View {
        HStack {
            Text(label)
                .font(.obsidianBody)
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
            Spacer()
            Link(destination: URL(string: url) ?? URL(string: "https://haynoi.com")!) {
                HStack(spacing: 3) {
                    Text(url.replacingOccurrences(of: "https://", with: ""))
                        .font(Font.custom("BeVietnamPro-Medium", size: 13))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.obsidianAccent(for: scheme))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, C.s3)
    }

    private var aboutDivider: some View {
        Rectangle()
            .fill(Color.obsidianDivider(for: scheme))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

// MARK: - Recording Banner Waveform (Signal Cyan bars)

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
                    // Use accent directly — it's on a cyan-washed bg so decorative use is fine
                    context.fill(path, with: .color(Color.obsidianAccent(for: scheme).opacity(0.85)))
                }
            }
        }
    }
}

// MARK: - UsageView (Obsidian reskin — retained for Insights / compatibility)

struct UsageView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(UsageTracker.currentMonthCount)")
                    .font(.obsidianMonoLG)
                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                    .monospacedDigit()
                Text("transcriptions this month")
                    .font(.obsidianBody)
                    .foregroundStyle(Color.obsidianLabel4(for: scheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(C.s6)
            .background(Color.obsidianSubtle(for: scheme))

            Rectangle()
                .fill(Color.obsidianDivider(for: scheme))
                .frame(height: 1)

            let stats = UsageTracker.stats
            if stats.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Text("No usage history yet.")
                        .font(.obsidianBody)
                        .foregroundStyle(Color.obsidianLabel4(for: scheme))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(stats, id: \.month) { item in
                            HStack {
                                Text(item.month)
                                    .font(.obsidianMonoSM)
                                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
                                    .monospacedDigit()
                                Spacer()
                                Text("\(item.count) transcriptions")
                                    .font(.obsidianCaption)
                                    .foregroundStyle(Color.obsidianLabel4(for: scheme))
                            }
                            .padding(.horizontal, C.s6)
                            .padding(.vertical, C.s3)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.obsidianDivider(for: scheme))
                                    .frame(height: 1)
                                    .padding(.leading, C.s6)
                            }
                        }
                    }
                }
            }
        }
        .background(Color.obsidianBackground(for: scheme))
    }
}
