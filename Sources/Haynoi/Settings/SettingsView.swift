import SwiftUI
import AVFoundation
import ApplicationServices

// MARK: - SettingsView (Calm)
//
// Structure is unchanged: 5 tabs, all controls/logic identical.
// Calm uses the native macOS grouped Form chrome (the calm board's right-hand
// System Settings facsimile mirrors exactly this native look), with calm-token
// accents (indigo links, success/warn semantics) on the few custom rows.

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            DictationTab()
                .tabItem { Label("Dictation", systemImage: "waveform") }
                .tag(1)

            DictionaryTab()
                .tabItem { Label("Dictionary & Snippets", systemImage: "book.closed") }
                .tag(2)

            AccountTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(3)

            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(4)
        }
        .frame(width: 520)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @AppStorage("hotkeyChoice") private var hotkeyChoice = "option"
    @AppStorage("appTheme") private var appTheme = "light"
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundTheme") private var soundTheme = "chime"
    @AppStorage("successDinkEnabled") private var successDinkEnabled = true
    @AppStorage("muteMusic") private var muteMusic = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            appearanceSection
            hotkeySection
            soundSection
            systemSection
            setupSection
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appTheme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            Text("Haynoi defaults to the light white-gray look. Choose System to follow macOS.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hotkeySection: some View {
        Section("Hotkey") {
            Picker("Push-to-talk key", selection: $hotkeyChoice) {
                Text("⌥ left Option").tag("option")
                Text("⌘ Command").tag("command")
                Text("⌃ Control").tag("control")
                Text("fn Globe").tag("fn")
            }
            .onChange(of: hotkeyChoice) { _, newValue in
                applyHotkey(newValue)
            }
            Text("Hold to record, release to transcribe. The right Option key stays free for accents.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var soundSection: some View {
        Section("Sounds") {
            Toggle("Sound feedback", isOn: $soundEnabled)
            if soundEnabled {
                Picker("Sound theme", selection: $soundTheme) {
                    Text("Chime").tag("chime")
                    Text("Deep Bass").tag("deep")
                    Text("Crystal").tag("crystal")
                    Text("Minimal").tag("minimal")
                }
                .onChange(of: soundTheme) { _, _ in
                    SoundFeedback.shared.reloadTheme()
                    SoundFeedback.shared.playStartTone()
                }
                Toggle("Subtle chime when text lands", isOn: $successDinkEnabled)
            }
            Toggle("Mute music while dictating", isOn: $muteMusic)
        }
    }

    private var systemSection: some View {
        Section("System") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }
        }
    }

    private var setupSection: some View {
        Section {
            Button("Restart Setup…") {
                UserDefaults.standard.set(false, forKey: "onboardingCompleted")
                NotificationCenter.default.post(name: .haynoiRestartSetup, object: nil)
            }
            .foregroundStyle(Color.calmWarn)
        } footer: {
            Text("Walks through permissions and account setup from the beginning.")
                .font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        Form {
            qualitySection
            languageSection
            modeSection
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
    }

    private var qualitySection: some View {
        Section("Transcription Quality") {
            Picker("Quality", selection: $sttQuality) {
                Text("Fast").tag("fast")
                Text("Quality").tag("quality")
            }
            .pickerStyle(.segmented)
            .disabled(authState.signedInEmail == nil)

            if authState.signedInEmail == nil {
                Text("Sign in to choose — free quality tier included.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(sttQuality == "quality"
                    ? "Best accuracy for Vietnamese and English — the default."
                    : "Cheaper and quick — fine for clear, simple speech.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var languageSection: some View {
        Section("Language") {
            Picker("Language", selection: $languageHint) {
                Text("Auto-detect").tag("auto")
                Text("Tiếng Việt").tag("vi")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
            Text(languageHintDescription)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modeSection: some View {
        Section("Transcription Mode") {
            Picker("Mode", selection: $modeRaw) {
                ForEach(TranscriptionMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text(currentModeDescription)
                .font(.caption).foregroundStyle(.secondary)
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
        default:     return "Whisper detects the language automatically. Best for mixed or uncertain input."
        }
    }
}

// MARK: - Dictionary & Snippets Tab

private struct DictionaryTab: View {
    @State private var newWord = ""
    @State private var snippetTrigger = ""
    @State private var snippetExpansion = ""

    var body: some View {
        Form {
            dictionarySection
            snippetSection
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
    }

    private var dictionarySection: some View {
        Section("Custom Dictionary") {
            HStack {
                TextField("Add word (name, term…)", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }
                Button("Add") { addWord() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            let words = CustomDictionary.words
            if words.isEmpty {
                Text("Add names or terms the model often gets wrong.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                        HStack(spacing: 4) {
                            Text(word).font(.caption)
                            Button {
                                CustomDictionary.remove(at: i)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private var snippetSection: some View {
        Section("Snippets") {
            HStack {
                TextField("Trigger", text: $snippetTrigger)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Expansion text", text: $snippetExpansion)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    guard !snippetTrigger.isEmpty, !snippetExpansion.isEmpty else { return }
                    SnippetManager.add(Snippet(trigger: snippetTrigger, expansion: snippetExpansion))
                    snippetTrigger = ""
                    snippetExpansion = ""
                }
            }

            let snips = SnippetManager.snippets
            if snips.isEmpty {
                Text("Say a trigger word and it expands to the full text.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snips) { snippet in
                    HStack {
                        Text(snippet.trigger).fontWeight(.medium)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        Text(snippet.expansion).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { SnippetManager.remove(id: snippet.id) } label: {
                            Image(systemName: "trash").font(.caption).foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func addWord() {
        CustomDictionary.add(newWord)
        newWord = ""
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

    var body: some View {
        Form {
            accountSection
            connectionSection
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
        .onAppear { BalanceManager.shared.refresh() }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Text("Test connection")
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button(testing ? "Testing…" : "Run test") { runConnectionTest() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(testing)
            }
            Text("Checks whether your dictation can reach our servers on each route. No charge — it doesn't transcribe.")
                .font(.caption).foregroundStyle(.secondary)

            if let report {
                ForEach(report.routes) { r in
                    HStack(spacing: 8) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.ok ? Color.calmSuccess : .orange)
                        Text(r.name).font(.callout)
                        Spacer()
                        Text(r.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(report.verdict)
                    .font(.caption)
                    .foregroundStyle(report.anyWorked ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
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

    private var accountSection: some View {
        Section("Account") {
            if authState.keyInvalid {
                sessionExpiredView
            } else if let email = authState.signedInEmail {
                signedInView(email: email)
            } else {
                signedOutView
            }
        }
    }

    @ViewBuilder
    private var sessionExpiredView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Session expired").font(.callout).fontWeight(.medium)
            }
            Text("Your API key was revoked. Sign in again to continue dictating.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(isSigningIn ? "Signing in…" : "Sign in again") { signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSigningIn)
                if isSigningIn { ProgressView().controlSize(.small) }
            }
            if !signInError.isEmpty {
                Text(signInError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func signedInView(email: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.calmSuccess)
            Text("Signed in as \(email)").font(.callout)
            Spacer()
            Button("Sign out") {
                KymaAuth.signOut()
                authState.didSignOut()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }

        if let balance = balanceManager.balance {
            if balance > 0 {
                HStack {
                    HStack(spacing: 4) {
                        Text(String(format: "$%.2f", balance))
                            .font(.system(size: 13).monospacedDigit())
                        Text("remaining")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                // Confirmed zero — a brand-new account's free credit stays
                // locked until the email is verified, so point them at the inbox.
                verifyEmailCard
            }
        }
        // balance == nil → still loading; show nothing rather than flash the
        // verify-email card at a funded user before the first fetch returns.
    }

    @ViewBuilder
    private var verifyEmailCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "envelope.badge")
                .foregroundStyle(Color.calmAccent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Almost there — check your inbox and verify your email to unlock your free $0.50, then you're ready to dictate.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Open kymaapi.com", destination: URL(string: "https://kymaapi.com")!)
                    .font(.caption)
                    .foregroundStyle(Color.calmAccent)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var signedOutView: some View {
        HStack(spacing: 8) {
            Button(isSigningIn ? "Signing in…" : "Sign in") { signIn() }
                .buttonStyle(.borderedProminent)
                .disabled(isSigningIn)
            if isSigningIn { ProgressView().controlSize(.small) }
        }
        if !signInError.isEmpty {
            Text(signInError).font(.caption).foregroundStyle(.red)
        }
        Text("Sign in to start dictating. Pay-as-you-go credits, no subscription.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func signIn() {
        signInError = ""
        isSigningIn = true
        Task { @MainActor in
            defer { isSigningIn = false }
            do {
                let token = try await KymaAuth.shared.signIn()
                authState.didSignIn(email: token.email)
                BalanceManager.shared.refresh()
            } catch KymaAuth.AuthError.cancelled {
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

    // Fix sheet state (D8 / D26) — replaces the old prompting calls
    @State private var showAxFixSheet = false

    var body: some View {
        Form {
            Section("Status") {
                // Microphone: keeps the standard system prompt (unchanged per SPEC F1.8)
                permissionRow(
                    "Microphone",
                    icon: "mic.fill",
                    description: "Required to record your voice.",
                    granted: micPermission
                ) {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { refreshPermissions() }
                    }
                }

                // Accessibility: drag-grant sheet instead of the old prompting call (D8).
                // This single permission now covers both typing transcribed text
                // AND detecting the push-to-talk hotkey (NSEvent monitors gate on
                // Accessibility), so Input Monitoring is no longer required.
                dragPermissionRow(
                    "Accessibility",
                    icon: "hand.raised.fill",
                    description: "Required to detect the hotkey and type into other apps.",
                    granted: axPermission,
                    showSheet: $showAxFixSheet
                )
                .sheet(isPresented: $showAxFixSheet, onDismiss: refreshPermissions) {
                    DragGrantSheetHost(
                        permissionType: .accessibility,
                        isPresented: $showAxFixSheet
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
        .onAppear { refreshPermissions() }
    }

    // Standard row for Microphone (system prompt flow)
    @ViewBuilder
    private func permissionRow(
        _ title: String,
        icon: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
                Text(title).font(.body)
                Spacer()
                if granted {
                    Text("Granted").foregroundStyle(.secondary).font(.caption)
                } else {
                    Button("Fix") { action() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Drag-grant row for Accessibility (D8)
    @ViewBuilder
    private func dragPermissionRow(
        _ title: String,
        icon: String,
        description: String,
        granted: Bool,
        showSheet: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
                Text(title).font(.body)
                Spacer()
                if granted {
                    Text("Granted").foregroundStyle(.secondary).font(.caption)
                } else {
                    Button("Fix") { showSheet.wrappedValue = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        // Non-prompting variant — no pre-registration (F1.7)
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
