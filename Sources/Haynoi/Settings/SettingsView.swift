import SwiftUI
import AVFoundation
import ApplicationServices

// MARK: - SettingsView (Obsidian Instrument — light-b-paper-v2)
//
// Custom obsidian-styled settings sheet. Replaces the native `Form` chrome
// which clashed with the polished main window. 5 tabs with a Signal Cyan
// underline tab bar (NOT NSTabView / .formStyle(.grouped)).
//
// Structure: General · Dictation · Plans & Billing · Account · Permissions
// All behavior, bindings, and state are preserved exactly. Only presentation changed.

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    // Land signed-out users straight on Account (the sign-in form); signed-in
    // users get the usual General tab.
    @State private var selectedTab: SettingsTab =
        AuthState.shared.signedInEmail == nil ? .account : .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
                .background(Color.obsidianDivider(for: scheme))
            tabContent
        }
        .frame(width: 520)
        .frame(minHeight: 480)
        .background(Color.obsidianBackground(for: scheme))
    }

    // MARK: Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, C.s3)
        .background(Color.obsidianSubtle(for: scheme))
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isActive = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 0) {
                Text(tab.label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(
                        isActive
                            ? Color.obsidianLabel(for: scheme)
                            : Color.obsidianLabel3(for: scheme)
                    )
                    .padding(.horizontal, C.s2)
                    .padding(.vertical, C.s3)
                    .lineLimit(1)

                // Signal Cyan 2px underline for active tab
                Rectangle()
                    .fill(isActive ? Color.obsidianAccent(for: scheme) : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .animation(.obsidianFade, value: selectedTab)
    }

    // MARK: Tab Content

    @ViewBuilder
    private var tabContent: some View {
        ScrollView {
            switch selectedTab {
            case .general:
                GeneralTab()
                    .padding(C.s5)
            case .dictation:
                DictationTab()
                    .padding(C.s5)
            case .billing:
                BillingTab()
                    .padding(C.s5)
            case .account:
                AccountTab()
                    .padding(C.s5)
            case .permissions:
                PermissionsTab()
                    .padding(C.s5)
            }
        }
    }
}

// MARK: - Settings Tab Enum

private enum SettingsTab: String, CaseIterable {
    case general    = "General"
    case dictation  = "Dictation"
    case billing    = "Plans & Billing"
    case account    = "Account"
    case permissions = "Permissions"

    var label: String { rawValue }
}

// MARK: - Section Header

private struct SectionEyebrow: View {
    let title: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.obsidianLabel3(for: scheme))
            .kerning(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }
}

// MARK: - Settings Row Container

private struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Color.obsidianSurface(for: scheme))
        .overlay(
            RoundedRectangle(cornerRadius: C.rMD)
                .stroke(Color.obsidianDivider(for: scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: C.rMD))
    }
}

// MARK: - Settings Row

private struct SettingsRow<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let showDivider: Bool
    let content: Content

    init(showDivider: Bool = true, @ViewBuilder content: () -> Content) {
        self.showDivider = showDivider
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, C.s4)
                .padding(.vertical, C.s3)
            if showDivider {
                Divider()
                    .background(Color.obsidianDivider(for: scheme))
            }
        }
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @AppStorage("hotkeyChoice") private var hotkeyChoice = "option"
    @AppStorage("fixThatHotkeyChoice") private var fixThatChoice = "ctrlOption"
    @AppStorage("appTheme") private var appTheme = "light"
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundTheme") private var soundTheme = "chime"
    @AppStorage("successDinkEnabled") private var successDinkEnabled = true
    @AppStorage("muteMusic") private var muteMusic = true
    /// Fraction of the original volume left audible while dictating over a call.
    @AppStorage("duckFraction") private var duckFraction = 0.2
    @AppStorage("signalAEnabled") private var signalAEnabled = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("shareUsageData") private var shareUsageData = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: C.s5) {
            captureSection
            soundsSection
            systemSection
            privacySection
            setupSection
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Privacy")

            SettingsCard {
                SettingsRow(showDivider: false) {
                    Toggle(isOn: $shareUsageData) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share anonymous usage data")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.obsidianLabel(for: scheme))
                            Text("Counts and feature usage only — never your dictated text. Helps us improve Haynoi.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(Color.obsidianAccent(for: scheme))
                    .onChange(of: shareUsageData) { _, on in Analytics.setEnabled(on) }
                }
            }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Capture")

            SettingsCard {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Push-to-talk key")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))

                        Picker("", selection: $hotkeyChoice) {
                            Text("⌥ Option").tag("option")
                            Text("⌘ Command").tag("command")
                            Text("⌃ Control").tag("control")
                            Text("fn Globe").tag("fn")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: hotkeyChoice) { _, newValue in
                            applyHotkey(newValue)
                        }

                        Text("Hold to record, release to transcribe. Right Option stays free for accents.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    }
                }

                SettingsRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Fix that")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))

                        Picker("", selection: $fixThatChoice) {
                            Text("⌃⌥ Control+Option").tag("ctrlOption")
                            Text("⌥⌥ Double-tap Option").tag("doubleOption")
                            Text("Off").tag("off")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: fixThatChoice) { _, v in
                            HotkeyManager.shared.fixThatChoice = v
                        }

                        Text("Tap right after a dictation, then say the corrected version.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    }
                }

                SettingsRow(showDivider: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Appearance")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))

                        Picker("", selection: $appTheme) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)

                        Text("Haynoi defaults to the light look. Choose System to follow macOS.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    }
                }
            }
        }
    }

    private var soundsSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Sounds")

            SettingsCard {
                SettingsRow {
                    Toggle(isOn: $soundEnabled) {
                        Text("Sound feedback")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))
                    }
                    .toggleStyle(.switch)
                    .tint(Color.obsidianAccent(for: scheme))
                }

                if soundEnabled {
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sound theme")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.obsidianLabel(for: scheme))

                            Picker("", selection: $soundTheme) {
                                Text("Chime").tag("chime")
                                Text("Deep Bass").tag("deep")
                                Text("Crystal").tag("crystal")
                                Text("Minimal").tag("minimal")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: soundTheme) { _, _ in
                                SoundFeedback.shared.reloadTheme()
                                SoundFeedback.shared.playStartTone()
                            }
                        }
                    }

                    SettingsRow {
                        Toggle(isOn: $successDinkEnabled) {
                            Text("Subtle chime when text lands")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.obsidianLabel(for: scheme))
                        }
                        .toggleStyle(.switch)
                        .tint(Color.obsidianAccent(for: scheme))
                    }
                }

                SettingsRow {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $muteMusic) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quiet other audio while dictating")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                                Text("Music and video pause, then resume. Calls and live audio only dip in volume — never paused.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Color.obsidianAccent(for: scheme))

                        if muteMusic {
                            HStack(spacing: C.s2) {
                                Text("Live audio level")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
                                Slider(value: $duckFraction, in: 0...0.6, step: 0.05)
                                    .tint(Color.obsidianAccent(for: scheme))
                                Text("\(Int((duckFraction * 100).rounded()))%")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
                                    .frame(width: 32, alignment: .trailing)
                            }
                        }
                    }
                }

                // v1.3 — Signal A kill-switch (default on, AX-cooperative apps only).
                SettingsRow(showDivider: false) {
                    Toggle(isOn: $signalAEnabled) {
                        Text("Học khi bạn sửa từ trong app (chỉ TextEdit, Notes, Pages, Mail)")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))
                    }
                    .toggleStyle(.switch)
                    .tint(Color.obsidianAccent(for: scheme))
                }
            }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "System")

            SettingsCard {
                SettingsRow(showDivider: false) {
                    Toggle(isOn: $launchAtLogin) {
                        Text("Launch at login")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))
                    }
                    .toggleStyle(.switch)
                    .tint(Color.obsidianAccent(for: scheme))
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.set(enabled: newValue)
                    }
                }
            }
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Setup")

            SettingsCard {
                SettingsRow(showDivider: false) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restart setup wizard")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.obsidianLabel(for: scheme))
                            Text("Walks through permissions and account setup from the beginning.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }
                        Spacer()
                        Button {
                            UserDefaults.standard.set(false, forKey: "onboardingCompleted")
                            NotificationCenter.default.post(name: .haynoiRestartSetup, object: nil)
                        } label: {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func applyHotkey(_ choice: String) {
        let mgr = HotkeyManager.shared
        switch choice {
        case "command": mgr.targetModifier = .maskCommand
        case "control": mgr.targetModifier = .maskControl
        case "fn": mgr.targetModifier = .maskSecondaryFn
        default: mgr.targetModifier = .maskAlternate
        }
        mgr.start()
        NSLog("[Haynoi] Hotkey changed to: %@", choice)
    }
}

// MARK: - Dictation Tab

private struct DictationTab: View {
    @AppStorage("transcriptionMode") private var modeRaw = TranscriptionMode.normal.rawValue
    @AppStorage("sttQuality") private var sttQuality = "quality"
    @AppStorage("languageHint") private var languageHint = "auto"
    @ObservedObject private var authState = AuthState.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: C.s5) {
            qualitySection
            languageSection
            modeSection
            dictionarySection
        }
    }

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Dictionary")
            DictionaryEditor()
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Quality")

            SettingsCard {
                SettingsRow(showDivider: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Transcription quality")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))

                        Picker("", selection: $sttQuality) {
                            Text("Fast").tag("fast")
                            Text("Quality").tag("quality")
                        }
                        .pickerStyle(.segmented)
                        .disabled(authState.signedInEmail == nil)

                        if authState.signedInEmail == nil {
                            Text("Sign in to choose — free quality tier included.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        } else {
                            Text(sttQuality == "quality"
                                ? "Best accuracy for Vietnamese and English — the default."
                                : "Cheaper and quick — fine for clear, simple speech.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }
                    }
                }
            }
        }
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Language")

            SettingsCard {
                SettingsRow(showDivider: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default language")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))

                        Picker("", selection: $languageHint) {
                            Text("Auto-detect").tag("auto")
                            Text("Tiếng Việt").tag("vi")
                            Text("English").tag("en")
                        }
                        .pickerStyle(.segmented)

                        Text(languageHintDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    }
                }
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Mode")

            SettingsCard {
                SettingsRow(showDivider: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default mode")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))

                        Picker("", selection: $modeRaw) {
                            ForEach(TranscriptionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(currentModeDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    }
                }
            }
        }
    }

    private var currentMode: TranscriptionMode {
        TranscriptionMode(rawValue: modeRaw) ?? .normal
    }

    private var currentModeDescription: String {
        switch currentMode {
        case .auto:   return "Adapts to the app you're in — formal for email, casual for chat."
        case .normal: return "Transcribes exactly what you say."
        case .clean:  return "Removes filler words like um, uh, à."
        case .email:  return "Rewrites as professional, well-structured text."
        }
    }

    private var languageHintDescription: String {
        switch languageHint {
        case "vi":   return "Always transcribes as Vietnamese — fastest for Vietnamese-only speakers."
        case "en":   return "Always transcribes as English."
        default:     return "Kyma detects the language automatically. Best for mixed or uncertain input."
        }
    }
}

// MARK: - Dictionary Editor
//
// Manual management surface for PersonalDictionary. A plain term ("Affitor")
// becomes a .term; flipping "Sửa lỗi chính tả" reveals a `wrong` field and
// creates a .replacement (wrong → right). Each row toggles `enabled` and can
// be deleted. v1: manual only — no auto-capture.

private struct DictionaryEditor: View {
    @Environment(\.colorScheme) private var scheme

    @State private var entries: [DictionaryEntry] = []
    @State private var rightField = ""
    @State private var wrongField = ""
    @State private var isReplacement = false

    private var canAdd: Bool {
        let r = rightField.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return false }
        if isReplacement {
            return !wrongField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        SettingsCard {
            // Add row
            SettingsRow(showDivider: !entries.isEmpty) {
                VStack(alignment: .leading, spacing: C.s2) {
                    HStack(spacing: C.s2) {
                        if isReplacement {
                            TextField("Wrong (what it hears)", text: $wrongField)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.obsidianLabel(for: scheme))
                                .textFieldStyle(.plain)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }
                        TextField(isReplacement ? "Right (correct form)" : "Add a word or name…", text: $rightField)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.obsidianLabel(for: scheme))
                            .textFieldStyle(.plain)
                            .onSubmit { addEntry() }

                        Button("Add") { addEntry() }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(canAdd
                                ? Color.obsidianAccent(for: scheme)
                                : Color.obsidianLabel3(for: scheme))
                            .buttonStyle(.plain)
                            .disabled(!canAdd)
                    }

                    Toggle("Sửa lỗi chính tả", isOn: $isReplacement)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        .toggleStyle(.checkbox)
                }
            }

            // Existing entries
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                SettingsRow(showDivider: idx < entries.count - 1) {
                    HStack(spacing: C.s2) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.right)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(entry.enabled
                                    ? Color.obsidianLabel(for: scheme)
                                    : Color.obsidianLabel3(for: scheme))
                            if entry.kind == .replacement, let wrong = entry.wrong {
                                Text("\(wrong) → \(entry.right)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
                            }
                        }

                        if entry.source == .learned {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.obsidianAccent(for: scheme))
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { entry.enabled },
                            set: { newValue in
                                PersonalDictionary.shared.setEnabled(newValue, id: entry.id)
                                reload()
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.7)
                        .frame(width: 36)

                        Button {
                            PersonalDictionary.shared.delete(id: entry.id)
                            reload()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func addEntry() {
        guard canAdd else { return }
        let r = rightField.trimmingCharacters(in: .whitespacesAndNewlines)
        if isReplacement {
            let w = wrongField.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = PersonalDictionary.shared.addReplacement(wrong: w, right: r, source: .manual)
        } else {
            _ = PersonalDictionary.shared.addTerm(r, source: .manual)
        }
        rightField = ""
        wrongField = ""
        // Metadata only: just the signal enum — never the term strings.
        Analytics.capture("dictionary_term_learned", ["signal": "manual"])
        reload()
    }

    private func reload() {
        // Newest first; manual + learned together.
        entries = PersonalDictionary.shared.all.sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - Plans & Billing Tab

private struct BillingTab: View {
    @State private var billingPeriod: BillingPeriod = .annual
    @ObservedObject private var billing = BillingManager.shared
    @Environment(\.colorScheme) private var scheme

    enum BillingPeriod { case monthly, annual }

    private var monthlyPrice: String { "$14.99" }
    private var annualMonthlyPrice: String { "$10.49" }
    private var annualTotalPrice: String { "$125.88" }

    var body: some View {
        VStack(alignment: .leading, spacing: C.s5) {
            currentPlanSection
            upgradeSection
            teamSection
        }
        .task { await billing.refresh() }
    }

    // MARK: Current Plan

    private var currentPlanSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Current Plan")

            SettingsCard {
                SettingsRow(showDivider: billing.isPro) {
                    HStack(spacing: C.s3) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(billing.isPro ? "Pro plan" : "Free plan")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.obsidianLabel(for: scheme))
                            Text(currentPlanDetail)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }
                        Spacer()
                        Text(billing.isPro ? "PRO" : "FREE")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.4)
                            .foregroundStyle(
                                billing.isPro
                                    ? Color.accentOnLight
                                    : Color.obsidianLabel3(for: scheme))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                billing.isPro
                                    ? Color.accent.opacity(0.08)
                                    : Color.obsidianHover(for: scheme))
                            .overlay(
                                Capsule().stroke(
                                    billing.isPro
                                        ? Color.accent.opacity(0.35)
                                        : Color.obsidianDivider(for: scheme),
                                    lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                }
                if billing.isPro {
                    SettingsRow(showDivider: false) {
                        HStack {
                            Text("Payment method, invoices, cancel")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                            Spacer()
                            Button("Manage subscription") {
                                Task { await billing.openPortal() }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.obsidianAccent(for: scheme))
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var currentPlanDetail: String {
        guard billing.isPro else {
            return "5,000 words / week  ·  Auto-detect language  ·  Normal mode only"
        }
        var detail = "Unlimited words  ·  All modes"
        if let sub = billing.subscription {
            let date = Date(timeIntervalSince1970: sub.currentPeriodEnd / 1000)
            let df = DateFormatter()
            df.dateStyle = .medium
            detail += sub.cancelAtPeriodEnd
                ? "  ·  Ends \(df.string(from: date))"
                : "  ·  Renews \(df.string(from: date))"
        }
        return detail
    }

    // MARK: Upgrade

    private var upgradeSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Upgrade")

            // Billing period toggle
            billingToggle

            // Plan cards
            HStack(alignment: .top, spacing: C.s3) {
                freePlanCard
                proPlanCard
            }
        }
    }

    private var billingToggle: some View {
        HStack(spacing: 4) {
            BillingPeriodButton(
                label: "Monthly",
                isActive: billingPeriod == .monthly
            ) { billingPeriod = .monthly }

            BillingPeriodButton(
                label: "Annual",
                badge: "Save 30%",
                isActive: billingPeriod == .annual
            ) { billingPeriod = .annual }
        }
        .padding(3)
        .background(Color(hex: "EEEEF0"))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.obsidianDivider(for: scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var freePlanCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Badge
            Text("FREE")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(Color(hex: "EEEEF0"))
                .overlay(Capsule().stroke(Color.obsidianDivider(for: scheme), lineWidth: 1))
                .clipShape(Capsule())
                .padding(.bottom, C.s2)

            // Price
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("$0")
                    .font(.system(.title, design: .monospaced).weight(.regular))
                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                Text("forever")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
            }
            .padding(.bottom, 2)

            // Price note spacer (keeps height aligned with Pro card)
            Text(" ")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.clear)
                .padding(.bottom, C.s3)

            Divider().background(Color.obsidianDivider(for: scheme))
                .padding(.bottom, C.s3)

            // Features
            PlanFeature(text: "5,000 words / week", included: true)
            PlanFeature(text: "Auto language detect", included: true)
            PlanFeature(text: "Normal mode only", included: false)
            PlanFeature(text: "All 4 modes", included: false)
            PlanFeature(text: "Priority transcription", included: false)

            Spacer(minLength: C.s5)

            // CTA
            Text("Current plan")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: C.rSM)
                        .stroke(Color.obsidianDivider(for: scheme), lineWidth: 1)
                )
        }
        .padding(C.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "F3F4F2"))
        .overlay(
            RoundedRectangle(cornerRadius: C.rLG)
                .stroke(Color.obsidianDivider(for: scheme).opacity(1.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: C.rLG))
    }

    private var proPlanCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top cyan accent stripe
            Rectangle()
                .fill(LinearGradient.calmAurora)
                .frame(height: 2)
                .padding(.horizontal, -C.s4)
                .padding(.top, -C.s4)
                .padding(.bottom, C.s3)

            // Badge
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.accent)
                    .frame(width: 5, height: 5)
                    .shadow(color: Color.accent.opacity(0.7), radius: 4)
                Text("PRO")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.5)
                    .foregroundStyle(Color.accentOnLight)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Color.accent.opacity(0.08))
            .overlay(Capsule().stroke(Color.accent.opacity(0.35), lineWidth: 1))
            .clipShape(Capsule())
            .padding(.bottom, C.s2)

            // Price — follows the Monthly/Annual toggle
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(billingPeriod == .monthly ? monthlyPrice : annualMonthlyPrice)
                    .font(.system(.title, design: .monospaced).weight(.regular))
                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                Text("/ month")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
            }
            .padding(.bottom, 2)

            Text(billingPeriod == .monthly
                 ? "Billed monthly. Cancel anytime."
                 : "Billed \(annualTotalPrice) / year. Cancel anytime.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                .padding(.bottom, C.s3)

            Divider().background(Color.obsidianDivider(for: scheme))
                .padding(.bottom, C.s3)

            PlanFeature(text: "Unlimited dictation", included: true)
            PlanFeature(text: "All 4 modes", included: true)
            PlanFeature(text: "Priority transcription", included: true)
            PlanFeature(text: "Highest-quality transcription", included: true)

            Spacer(minLength: C.s5)

            proCTA
        }
        .padding(C.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.obsidianSurface(for: scheme))
        .overlay(
            RoundedRectangle(cornerRadius: C.rLG)
                .stroke(Color.obsidianDivider(for: scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: C.rLG))
    }

    @ViewBuilder
    private var proCTA: some View {
        if billing.isPro {
            Text("Current plan")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: C.rSM)
                        .stroke(Color.obsidianDivider(for: scheme), lineWidth: 1)
                )
        } else if billing.awaitingCheckout {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for payment…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.obsidianSubtle(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: C.rSM))
        } else {
            VStack(spacing: 4) {
                Button {
                    Analytics.capture("upgrade_clicked", [
                        "cycle": billingPeriod == .monthly ? "monthly" : "annual",
                    ])
                    Task {
                        await billing.startCheckout(
                            cycle: billingPeriod == .monthly ? "monthly" : "annual")
                    }
                } label: {
                    Text("Upgrade to Pro")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: C.rSM))
                }
                .buttonStyle(.plain)

                if let err = billing.lastError {
                    Text(err)
                        .font(.system(size: 10.5))
                        .foregroundStyle(scheme == .dark ? Color.obsidianDarkError : Color.obsidianError)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: Team

    private var teamSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Team")

            SettingsCard {
                SettingsRow(showDivider: false) {
                    HStack(spacing: C.s3) {
                        // Team icon
                        RoundedRectangle(cornerRadius: C.rSM)
                            .fill(Color.obsidianHover(for: scheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: C.rSM)
                                    .stroke(Color.obsidianDivider(for: scheme), lineWidth: 1)
                            )
                            .frame(width: 32, height: 32)
                            .overlay(
                                Image(systemName: "person.3")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Team plan")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.obsidianLabel(for: scheme))
                            Text("Shared credits, admin dashboard, team Dictionary sync.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }

                        Spacer()

                        // "Sắp có" badge
                        Text("Sắp có")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.3)
                            .foregroundStyle(Color.obsidianWarn(for: scheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.obsidianWarn(for: scheme).opacity(0.09))
                            .overlay(
                                Capsule()
                                    .stroke(Color.obsidianWarn(for: scheme).opacity(0.22), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - BillingPeriodButton

private struct BillingPeriodButton: View {
    let label: String
    var badge: String? = nil
    let isActive: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isActive
                            ? Color.obsidianLabel(for: scheme)
                            : Color.obsidianLabel3(for: scheme)
                    )

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.3)
                        .foregroundStyle(Color.accentOnLight)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accent.opacity(0.08))
                        .overlay(Capsule().stroke(Color.accent.opacity(0.35), lineWidth: 1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                isActive
                    ? Color.obsidianSurface(for: scheme)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(
                color: isActive ? Color.black.opacity(0.10) : .clear,
                radius: 3, y: 1
            )
        }
        .buttonStyle(.plain)
        .animation(.obsidianFade, value: isActive)
    }
}

// MARK: - PlanFeature row

private struct PlanFeature: View {
    let text: String
    let included: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: C.s2) {
            // Checkmark circle
            ZStack {
                Circle()
                    .fill(included ? Color.accent.opacity(0.08) : Color.clear)
                    .overlay(
                        Circle().stroke(
                            included ? Color.accent.opacity(0.35) : Color.obsidianDivider(for: scheme),
                            lineWidth: 1
                        )
                    )
                    .frame(width: 14, height: 14)

                if included {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color.accentOnLight)
                }
            }
            .padding(.top, 1)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(
                    included
                        ? Color.obsidianLabel2(for: scheme)
                        : Color.obsidianLabel4(for: scheme)
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 7)
    }
}

// MARK: - Account Tab

private struct AccountTab: View {
    @ObservedObject private var authState = AuthState.shared
    @ObservedObject private var balanceManager = BalanceManager.shared
    @State private var isSigningIn = false
    @State private var signInError = ""
    @State private var testing = false
    @State private var report: STTProvider.ConnectionReport?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: C.s5) {
            accountSection
            connectionSection
        }
        .onAppear { BalanceManager.shared.refresh() }
    }

    // MARK: Account Section

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Signed In")

            SettingsCard {
                if authState.keyInvalid {
                    SettingsRow(showDivider: false) { sessionExpiredView }
                } else if let email = authState.signedInEmail {
                    signedInRows(email: email)
                } else {
                    SettingsRow(showDivider: false) { signedOutView }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionExpiredView: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.obsidianWarn(for: scheme))
                Text("Session expired")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.obsidianLabel(for: scheme))
            }
            Text("Your session expired. Sign in again to continue dictating.")
                .font(.system(size: 11))
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
            HStack(spacing: C.s2) {
                Button(isSigningIn ? "Signing in…" : "Continue with Google") { signInWithGoogle() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentOnLight)
                    .disabled(isSigningIn)
                if isSigningIn { ProgressView().controlSize(.small) }
            }
            if !signInError.isEmpty {
                Text(signInError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.obsidianError)
            }
        }
    }

    @ViewBuilder
    private func signedInRows(email: String) -> some View {
        SettingsRow {
            HStack(spacing: C.s3) {
                // Avatar circle with cyan accent
                ZStack {
                    Circle()
                        .fill(Color.accent.opacity(0.12))
                        .overlay(Circle().stroke(Color.accent.opacity(0.35), lineWidth: 1))
                        .frame(width: 32, height: 32)
                    Text(String(email.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentOnLight)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(email)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.obsidianLabel(for: scheme))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.obsidianSuccess(for: scheme))
                            .frame(width: 6, height: 6)
                        Text("Signed in")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    }
                }

                Spacer()

                Button("Sign out") {
                    HaynoiAuth.signOut()
                    authState.didSignOut()
                    Analytics.capture("signed_out")
                    Analytics.reset()
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                .buttonStyle(.plain)
            }
        }

        // Plan / quota row
        if let tier = balanceManager.tier {
            SettingsRow(showDivider: false) {
                VStack(alignment: .leading, spacing: C.s2) {
                    Text(planLabel(tier: tier))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.obsidianLabel(for: scheme))
                    if let cap = balanceManager.wordsCap, cap > 0,
                       let used = balanceManager.wordsUsed {
                        Text("\(used) / \(cap) words used this week")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    } else {
                        Text("Unlimited dictation.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.obsidianLabel3(for: scheme))
                    }
                }
            }
        }
    }

    /// Friendly plan line from the usage tier. cap == 0 means unlimited.
    private func planLabel(tier: String) -> String {
        switch tier {
        case "pro": return "Pro — unlimited"
        case "max": return "Max — unlimited"
        default:    return "Free — 5,000 words / week"
        }
    }

    @ViewBuilder
    private var signedOutView: some View {
        VStack(alignment: .leading, spacing: C.s3) {
            HStack(spacing: C.s2) {
                Button(isSigningIn ? "Opening browser…" : "Continue with Google") {
                    signInWithGoogle()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentOnLight)
                .disabled(isSigningIn)
                if isSigningIn { ProgressView().controlSize(.small) }
            }

            if !signInError.isEmpty {
                Text(signInError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.obsidianError)
            }
            Text("Free tier: 5,000 words / week. No credit card.")
                .font(.system(size: 11))
                .foregroundStyle(Color.obsidianLabel3(for: scheme))
        }
    }

    // MARK: Connection Section

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: C.s2) {
            SectionEyebrow(title: "Connection")

            SettingsCard {
                SettingsRow(showDivider: report != nil) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Test connection")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.obsidianLabel(for: scheme))
                            Text("Checks whether your dictation can reach our servers. No charge.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.obsidianLabel3(for: scheme))
                        }
                        Spacer()
                        if testing { ProgressView().controlSize(.small) }
                        Button(testing ? "Testing…" : "Run test →") { runConnectionTest() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.obsidianAccent(for: scheme))
                            .buttonStyle(.plain)
                            .disabled(testing)
                    }
                }

                if let report {
                    ForEach(report.routes.indices, id: \.self) { idx in
                        let r = report.routes[idx]
                        SettingsRow(showDivider: idx < report.routes.count - 1) {
                            HStack(spacing: C.s2) {
                                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(r.ok ? Color.obsidianSuccess(for: scheme) : Color.obsidianWarn(for: scheme))
                                Text(r.name)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                                Spacer()
                                Text(r.detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
                            }
                        }
                    }

                    SettingsRow(showDivider: false) {
                        Text(report.verdict)
                            .font(.system(size: 11))
                            .foregroundStyle(
                                report.anyWorked
                                    ? Color.obsidianLabel3(for: scheme)
                                    : Color.obsidianWarn(for: scheme)
                            )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func runConnectionTest() {
        testing = true
        report = nil
        Task {
            let result = await STTProvider.runConnectionTest()
            await MainActor.run { report = result; testing = false }
        }
    }

    private func signInWithGoogle() {
        signInError = ""
        isSigningIn = true
        Task { @MainActor in
            defer { isSigningIn = false }
            do {
                let user = try await HaynoiAuth.shared.signInWithGoogle()
                authState.didSignIn(email: user.email)
                Analytics.identify(user.id)
                Analytics.capture("signed_in", ["method": "google"])
                BalanceManager.shared.refresh()
            } catch HaynoiAuth.AuthError.cancelled {
                // user closed the auth window — no error to show
            } catch {
                signInError = error.localizedDescription
            }
        }
    }
}

// MARK: - Permissions Tab

private struct PermissionsTab: View {
    @State private var micPermission = false
    @State private var axPermission = false
    @State private var showAxFixSheet = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: C.s5) {
            SectionEyebrow(title: "Permissions")

            SettingsCard {
                // Microphone
                SettingsRow {
                    permissionRow(
                        "Microphone",
                        icon: "mic.fill",
                        description: "Required to capture your voice.",
                        granted: micPermission
                    ) {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async { refreshPermissions() }
                        }
                    }
                }

                // Accessibility (drag-grant)
                SettingsRow(showDivider: false) {
                    dragPermissionRow(
                        "Accessibility",
                        icon: "hand.raised.fill",
                        description: "Required to insert text into other apps.",
                        granted: axPermission,
                        showSheet: $showAxFixSheet
                    )
                }
                .sheet(isPresented: $showAxFixSheet, onDismiss: refreshPermissions) {
                    DragGrantSheetHost(
                        permissionType: .accessibility,
                        isPresented: $showAxFixSheet
                    )
                }
            }
        }
        .onAppear { refreshPermissions() }
    }

    @ViewBuilder
    private func permissionRow(
        _ title: String,
        icon: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: C.s2) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.obsidianSuccess(for: scheme) : Color.obsidianError)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
            }

            Spacer()

            if granted {
                Text("Granted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.obsidianSuccess(for: scheme))
            } else {
                Button("Fix") { action() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.obsidianAccent(for: scheme))
                    .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func dragPermissionRow(
        _ title: String,
        icon: String,
        description: String,
        granted: Bool,
        showSheet: Binding<Bool>
    ) -> some View {
        HStack(spacing: C.s2) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.obsidianSuccess(for: scheme) : Color.obsidianError)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.obsidianLabel(for: scheme))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.obsidianLabel3(for: scheme))
            }

            Spacer()

            if granted {
                Text("Granted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.obsidianSuccess(for: scheme))
            } else {
                Button("Fix") { showSheet.wrappedValue = true }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.obsidianAccent(for: scheme))
                    .buttonStyle(.plain)
            }
        }
    }

    private func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axPermission = AXIsProcessTrusted()
    }
}

// MARK: - Flow Layout (tag cloud for dictionary words)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
