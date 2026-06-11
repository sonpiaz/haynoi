import SwiftUI
import AVFoundation
import ApplicationServices

struct SettingsView: View {
    @AppStorage("transcriptionMode") private var modeRaw = TranscriptionMode.normal.rawValue
    @AppStorage("sttQuality") private var sttQuality = "quality"  // "quality" (default) | "fast"
    // Fix #4: "auto" is the new-install default — omits the language field so
    // Whisper detects freely. Existing users who never set this key also land on
    // "auto", which is conservative and never worse than the old "vi" hardcode.
    @AppStorage("languageHint") private var languageHint = "auto"
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("soundTheme") private var soundTheme = "deep"
    @AppStorage("muteMusic") private var muteMusic = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("hotkeyChoice") private var hotkeyChoice = "command"
    @State private var micPermission = false
    @State private var axPermission = false
    @State private var inputMonitoring = false
    @State private var newWord = ""
    @State private var snippetTrigger = ""
    @State private var snippetExpansion = ""
    @State private var signInError = ""
    @State private var isSigningIn = false
    // Fix #3: credit balance — fetched on Settings open + after each session.
    @State private var creditBalance: Double? = nil
    @State private var isFetchingBalance = false
    // Fix #1: observe the shared auth state so every surface stays in sync.
    @ObservedObject private var authState = AuthState.shared

    var body: some View {
        Form {
            accountSection
            qualitySection
            languageSection
            modeSection
            hotkeySection
            dictionarySection
            snippetSection
            systemSection
            permissionSection
        }
        .formStyle(.grouped)
        .onAppear {
            refreshPermissions()
            refreshBalance()
        }
        .onReceive(NotificationCenter.default.publisher(for: .haynoiDictationCompleted)) { _ in
            // Fix #3: a dictation completed — refresh balance if Settings is open.
            refreshBalance()
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section("Account") {
            if authState.keyInvalid {
                // Fix #1: key was revoked (401) — show a prominent re-auth prompt.
                // The keychain has already been cleared by AuthState.handleKeyRevoked().
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Session expired").font(.callout).fontWeight(.medium)
                    }
                    Text("Your API key was revoked. Please sign in again to continue dictating.")
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
            } else if let email = authState.signedInEmail {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Signed in as \(email)").font(.callout)
                    Spacer()
                    Button("Sign out") {
                        KymaAuth.signOut()
                        authState.didSignOut()
                        creditBalance = nil
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                // Fix #3: credit balance line — hidden when fetch hasn't returned yet
                // or if the server returned an unexpected shape (defensive hide).
                if let balance = creditBalance {
                    HStack {
                        if balance < 0.05 {
                            // Fix #2: out-of-credits UX — clickable top-up link.
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            Text("Out of credits —")
                                .font(.caption).foregroundStyle(.secondary)
                            Link("top up at kymaapi.com",
                                 destination: URL(string: "https://kymaapi.com")!)
                                .font(.caption)
                        } else {
                            Image(systemName: "creditcard").foregroundStyle(.secondary)
                            Text(String(format: "$%.2f remaining", balance))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isFetchingBalance {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button(isSigningIn ? "Signing in…" : "Sign in") { signIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSigningIn)
                    if isSigningIn {
                        ProgressView().controlSize(.small)
                    }
                }
                if !signInError.isEmpty {
                    Text(signInError).font(.caption).foregroundStyle(.red)
                }
                Text("Sign in to start dictating. Pay-as-you-go credits, no subscription.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var languageSection: some View {
        // Fix #4: language preference — global-first default is "auto".
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

    private var qualitySection: some View {
        Section("Transcription Quality") {
            Picker("Quality", selection: $sttQuality) {
                Text("Fast").tag("fast")
                Text("Quality").tag("quality")
            }
            .pickerStyle(.segmented)
            .disabled(authState.signedInEmail == nil)

            Text(sttQuality == "quality"
                ? "Best accuracy for Vietnamese + English — the default."
                : "Cheaper and quick — fine for clear, simple speech.")
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
            Text(currentMode.description)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hotkeySection: some View {
        Section("Hotkey") {
            Picker("Push-to-talk key", selection: $hotkeyChoice) {
                Text("⌘ Command").tag("command")
                Text("⌥ Option").tag("option")
                Text("⌃ Control").tag("control")
                Text("fn Globe").tag("fn")
            }
            .onChange(of: hotkeyChoice) { _, newValue in
                applyHotkey(newValue)
            }
            Text("Hold to record, release to transcribe")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dictionarySection: some View {
        Section("Custom Dictionary") {
            HStack {
                TextField("Add word (name, term...)", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }
                Button("Add") { addWord() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            let words = CustomDictionary.words
            if words.isEmpty {
                Text("Add names or terms the model gets wrong")
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
                Text("Say a trigger word → expands to full text")
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

    private var systemSection: some View {
        Section("System") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(enabled: newValue)
                }
            Toggle("Sound feedback", isOn: $soundEnabled)
            if soundEnabled {
                Picker("Sound theme", selection: $soundTheme) {
                    Text("Deep Bass").tag("deep")
                    Text("Crystal").tag("crystal")
                    Text("Minimal").tag("minimal")
                }
                .onChange(of: soundTheme) { _, _ in
                    SoundFeedback.shared.reloadTheme()
                    SoundFeedback.shared.playStartTone()
                }
            }
            Toggle("Mute music while dictating", isOn: $muteMusic)
        }
    }

    private var permissionSection: some View {
        Section("Permissions") {
            permissionRow("Microphone", granted: micPermission) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { refreshPermissions() }
                }
            }
            permissionRow("Accessibility", granted: axPermission) {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
                refreshPermissions()
            }
            permissionRow("Input Monitoring", granted: inputMonitoring) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - Helpers

    private var currentMode: TranscriptionMode {
        TranscriptionMode(rawValue: modeRaw) ?? .normal
    }

    private var languageHintDescription: String {
        switch languageHint {
        case "vi": return "Always transcribe as Vietnamese — fastest for Vi-only speakers."
        case "en": return "Always transcribe as English."
        default:   return "Whisper detects the language automatically. Best for mixed or uncertain input."
        }
    }

    private func addWord() {
        CustomDictionary.add(newWord)
        newWord = ""
    }

    private func applyHotkey(_ choice: String) {
        let mgr = HotkeyManager.shared
        switch choice {
        case "option": mgr.targetModifier = .maskAlternate
        case "control": mgr.targetModifier = .maskControl
        case "fn": mgr.targetModifier = .maskSecondaryFn
        default: mgr.targetModifier = .maskCommand
        }
        mgr.start()
        NSLog("[Haynoi] Hotkey changed to: %@", choice)
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted {
                Button("Grant") { action() }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Text("Granted").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axPermission = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
    }

    private func signIn() {
        signInError = ""
        isSigningIn = true
        Task { @MainActor in
            defer { isSigningIn = false }
            do {
                let token = try await KymaAuth.shared.signIn()
                // Fix #1: update shared AuthState so every surface reflects the new email.
                authState.didSignIn(email: token.email)
                // Fetch balance immediately after sign-in.
                refreshBalance()
            } catch KymaAuth.AuthError.cancelled {
                // user closed the auth window — no error to show
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    // MARK: - Balance Fetch (Fix #3)

    /// Fetches /v1/credits/balance and updates creditBalance.
    /// Called on Settings open and can be called from PipelineController after
    /// a successful dictation (lightweight async fire).
    func refreshBalance() {
        guard let apiKey = KymaAuth.currentApiKey else { return }
        guard !isFetchingBalance else { return }
        isFetchingBalance = true
        Task { @MainActor in
            defer { isFetchingBalance = false }
            do {
                let balance = try await fetchCreditBalance(apiKey: apiKey)
                creditBalance = balance
            } catch {
                // Defensive: hide the balance line on any parse or network failure.
                // NSLog detail stays for debugging; UI silently omits the line.
                NSLog("[Haynoi] Balance fetch failed: %@", error.localizedDescription)
            }
        }
    }

    /// GET https://api.kymaapi.com/v1/credits/balance
    /// Response shape: { balance: Double, low_balance: Bool, ... }
    private func fetchCreditBalance(apiKey: String) async throws -> Double {
        var req = URLRequest(url: URL(string: "https://api.kymaapi.com/v1/credits/balance")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = json["balance"] as? Double else {
            throw URLError(.cannotParseResponse)
        }
        return balance
    }
}

// MARK: - Flow Layout (tag cloud for dictionary words)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
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
