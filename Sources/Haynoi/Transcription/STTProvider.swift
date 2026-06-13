import AVFoundation
import Foundation
import Network

// MARK: - STT Provider
//
// All transcription routed through Kyma. Two quality tiers picked by user:
//   "quality" → gpt-4o-mini-transcribe-2025-12-15 (default — best Vi/En accuracy)
//   "fast"    → whisper-v3-turbo (cheaper, clear speech only)
//
// User must be signed in via KymaAuth (device code flow).
// No BYOK — single hosted backend, single sign-in.

enum STTProvider {
    static func transcribe(_ samples: [Float]) async throws -> String {
        guard let apiKey = KymaAuth.currentApiKey else {
            throw STTError.notSignedIn
        }

        let mode = TranscriptionMode.current.resolved
        let wavData = try createWAV(samples: samples, sampleRate: 16000)
        let model = resolveModel()

        // Language preference: @AppStorage "languageHint" values — "auto", "vi", "en".
        // Whisper treats `prompt` as continuation CONTEXT, not instructions —
        // an all-English instruction string biases its decoder toward ENGLISH
        // output (Vietnamese speech comes back translated/garbled). Only the
        // gpt-4o transcribe family follows instructions; whisper gets
        // language-appropriate context + raw vocabulary instead.
        let languageHint = UserDefaults.standard.string(forKey: "languageHint") ?? "auto"
        let prompt: String
        if model == "transcribe-quality" {
            prompt = CustomDictionary.promptFragment + mode.sttPrompt
        } else {
            let vocab = CustomDictionary.words.filter { !$0.isEmpty }.joined(separator: ", ")
            switch languageHint {
            case "vi":
                prompt = "Đây là đoạn nói tiếng Việt, thỉnh thoảng xen vài từ tiếng Anh."
                    + (vocab.isEmpty ? "" : " Từ vựng: \(vocab).")
            case "en":
                // English context — give Whisper a natural English-language seed
                // so its decoder stays in English even when background noise is present.
                prompt = "This is spoken English."
                    + (vocab.isEmpty ? "" : " Terms: \(vocab).")
            default:
                // auto: omit prompt entirely — a language-specific prompt biases the
                // decoder toward that language even when the speaker uses the other.
                // Let Whisper detect freely.
                prompt = vocab.isEmpty ? "" : "Terms: \(vocab)."
            }
        }

        var text = try await callKymaTranscribe(
            apiKey: apiKey, wavData: wavData, model: model, prompt: prompt,
            languageHint: languageHint
        )

        if mode.needsRewrite, !text.isEmpty {
            text = try await rewriteWithKyma(
                apiKey: apiKey, text: text, systemPrompt: mode.rewritePrompt
            )
        }
        return text
    }

    /// Resolves Kyma model alias from user's quality setting.
    private static func resolveModel() -> String {
        let quality = UserDefaults.standard.string(forKey: "sttQuality") ?? "quality"
        return quality == "quality" ? "transcribe-quality" : "transcribe"
    }

    // MARK: - Kyma API calls

    // Data-plane goes straight to the API edge (skips the website proxy hop).
    // Auth stays on kymaapi.com (browser flow) — see KymaAuth.baseURL.
    private static let kymaBaseURL = "https://api.kymaapi.com"
    // Fallback ladder — three DIFFERENT network paths (live-debugged
    // 2026-06-12: a VN user's request HEADERS reached auth but the multipart
    // BODY never completed; direct OpenAI from the same machine was fine):
    //   1. api.kymaapi.com — Cloudflare edge → native Worker
    //   2. kymaapi.com     — Cloudflare edge → Vercel proxy → Railway
    //   3. Railway host    — Railway's own edge, NO Cloudflare at all —
    //      rescues ISPs whose route into the Cloudflare anycast is broken.
    private static let kymaFallbackBaseURL = "https://kymaapi.com"
    private static let kymaDirectBaseURL = "https://kyma-api-production.up.railway.app"

    private static var routeBases: [String] {
        [kymaBaseURL, kymaFallbackBaseURL, kymaDirectBaseURL]
    }

    /// The route that most recently worked (or probed fastest). Persisted, so
    /// a user whose ISP stalls the primary edge pays the rescue delay AT MOST
    /// once — every later dictation goes straight to their good route.
    private static var preferredBase: String {
        get {
            let v = UserDefaults.standard.string(forKey: "kymaPreferredRoute") ?? kymaBaseURL
            return routeBases.contains(v) ? v : kymaBaseURL
        }
        set { UserDefaults.standard.set(newValue, forKey: "kymaPreferredRoute") }
    }

    // Re-probe triggers: app launch AND every network-path change (Wi-Fi
    // switch, VPN toggle, wake in a new location). The app is a menu-bar
    // resident that can run for weeks — launch-only probing would go stale.
    private static let pathMonitor = NWPathMonitor()
    private static var monitorStarted = false
    private static var lastProbeAt = Date.distantPast
    private static let probeLock = NSLock()

    static func startRouteMonitoring() {
        guard !monitorStarted else { return }
        monitorStarted = true
        probeRoutesInBackground()
        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            NSLog("[Haynoi] Network path changed — re-probing routes")
            probeRoutesInBackground()
        }
        pathMonitor.start(queue: DispatchQueue(label: "haynoi.route-monitor"))
    }

    /// Fire-and-forget probe of all routes (tiny GET /v1/health — 93 bytes,
    /// free + no-auth, no model inference so it never bills credits). The
    /// fastest healthy route becomes preferred, so even the FIRST dictation
    /// after launch uses a route that is known to work from this network.
    /// Debounced: path changes arrive in bursts when switching networks.
    static func probeRoutesInBackground() {
        probeLock.lock()
        let tooSoon = Date().timeIntervalSince(lastProbeAt) < 10
        if !tooSoon { lastProbeAt = Date() }
        probeLock.unlock()
        if tooSoon { return }
        runProbe()
    }

    private static func runProbe() {
        Task.detached(priority: .utility) {
            var best: (base: String, ms: Double)?
            await withTaskGroup(of: (String, Double)?.self) { group in
                for base in routeBases {
                    group.addTask {
                        // /v1/health is 93 bytes (vs 71 KB for /v1/models) —
                        // a probe only needs liveness + latency, not the model
                        // list. 768× less bandwidth per probe round.
                        var req = URLRequest(url: URL(string: "\(base)/v1/health")!)
                        req.timeoutInterval = 5
                        let t0 = Date()
                        guard let (_, resp) = try? await URLSession.shared.data(for: req),
                              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                        return (base, Date().timeIntervalSince(t0) * 1000)
                    }
                }
                for await result in group {
                    if let result, best == nil || result.1 < best!.ms {
                        best = (result.0, result.1)
                    }
                }
            }
            if let best {
                preferredBase = best.base
                NSLog("[Haynoi] Route probe: %@ wins (%.0f ms)", best.base, best.ms)
            }
        }
    }

    private static func callKymaTranscribe(
        apiKey: String, wavData: Data, model: String, prompt: String,
        languageHint: String
    ) async throws -> String {
        let boundary = UUID().uuidString

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model)\r\n")

        // Only append a prompt field when there is content to send.
        // An empty prompt wastes bytes and gives Whisper a blank context window.
        if !prompt.isEmpty {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            body.append("\(prompt)\r\n")
        }

        // Fix #4: language field is omitted for "auto" so Whisper detects freely.
        // Sending a language code biases the decoder — correct for explicit choices,
        // wrong for auto-detect (the previous hardcoded "vi" hurt English speakers).
        if languageHint == "vi" || languageHint == "en" {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.append("\(languageHint)\r\n")
        }

        body.append("--\(boundary)--\r\n")

        func makeRequest(base: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "\(base)/v1/audio/transcriptions")!)
            request.httpMethod = "POST"
            // 30s IDLE timeout (URLSession resets it whenever bytes move, so a
            // slow-but-progressing upload is safe). A genuine stall now fails
            // in 30s and the next network in the ladder takes over — with the
            // old 90s a stalled network meant minutes before the fallback ran.
            request.timeoutInterval = 30
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }

        // Hedged race (v0.3.0): the preferred route fires immediately; each
        // remaining route joins IN PARALLEL 4s later if no answer yet. First
        // success wins and becomes the preferred route for next time. A user
        // on a stalled network pays the hedge delay once (~4-8s), then every
        // later dictation goes straight to their working route at full speed.
        // Trade-off: when the preferred route is merely slow (>4s, ~p99) a
        // duplicate transcription may complete upstream and double-bill that
        // one dictation — pennies, accepted to never lose the user's words.
        let order = [preferredBase] + routeBases.filter { $0 != preferredBase }
        return try await withThrowingTaskGroup(of: RaceOutcome.self) { group in
            for (i, base) in order.enumerated() {
                let request = makeRequest(base: base)
                group.addTask {
                    if i > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(i) * 4_000_000_000)
                        if Task.isCancelled { return .routeFailed(STTError.noConnection) }
                    }
                    return await attemptRoute(base: base, request: request)
                }
            }

            var lastFailure: Error = STTError.noConnection
            var failures = 0
            for try await outcome in group {
                switch outcome {
                case .success(let text, let base):
                    if base != preferredBase {
                        NSLog("[Haynoi] Route %@ rescued the dictation — now preferred", base)
                        preferredBase = base
                    }
                    group.cancelAll()
                    return text
                case .fatal(let error):
                    group.cancelAll()
                    throw error
                case .routeFailed(let error):
                    failures += 1
                    lastFailure = error
                }
            }
            _ = failures
            throw lastFailure
        }
    }

    /// One transcription attempt against one route. Never throws — returns a
    /// race outcome so the hedged group can decide.
    private enum RaceOutcome {
        case success(String, base: String)
        case routeFailed(Error)   // try another route
        case fatal(Error)         // same answer everywhere — stop the race
    }

    private static func attemptRoute(base: String, request: URLRequest) async -> RaceOutcome {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .routeFailed(STTError.noConnection)
            }
            switch http.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    return .routeFailed(STTError.parseError)
                }
                return .success(text.trimmingCharacters(in: .whitespacesAndNewlines), base: base)
            case 401:
                // Key was revoked server-side — sign out locally and notify UI.
                NSLog("[Haynoi] 401 from %@ — key revoked, signing out", base)
                await MainActor.run { AuthState.shared.handleKeyRevoked() }
                NotificationHelper.postSessionExpired()
                return .fatal(STTError.sessionExpired)
            case 402:
                NSLog("[Haynoi] 402 from %@ — out of credits", base)
                return .fatal(STTError.outOfCredits)
            case 429:
                NSLog("[Haynoi] Rate limited via %@", base)
                return .routeFailed(STTError.rateLimited)
            case 500...:
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                NSLog("[Haynoi] Transcription API error %d via %@: %@", http.statusCode, base, rawBody)
                return .routeFailed(STTError.serverError(
                    parseKymaErrorMessage(data: data)
                        ?? "Something went wrong (HTTP \(http.statusCode)) — try again"))
            default:
                // Real 4xx client errors — every route gives the same answer.
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                NSLog("[Haynoi] Transcription API error %d via %@: %@", http.statusCode, base, rawBody)
                return .fatal(STTError.serverError(
                    parseKymaErrorMessage(data: data)
                        ?? "Something went wrong (HTTP \(http.statusCode)) — try again"))
            }
        } catch let urlErr as URLError {
            NSLog("[Haynoi] Transport error via %@: %@", base, urlErr.localizedDescription)
            return .routeFailed(STTError.noConnection)
        } catch {
            return .routeFailed(error)
        }
    }

    /// Extracts the human-readable message from a Kyma error envelope.
    /// Shape: {"error":{"message":"..."}} — same as OpenAI error format.
    /// Returns nil on parse failure so callers can substitute their own copy.
    private static func parseKymaErrorMessage(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any],
              let message = errorObj["message"] as? String,
              !message.isEmpty else {
            return nil
        }
        return message
    }

    private static func rewriteWithKyma(
        apiKey: String, text: String, systemPrompt: String
    ) async throws -> String {
        let url = URL(string: "\(kymaBaseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            // Benchmarked 2026-06-10: gemini-2.5-flash 1.7s clean output;
            // qwen-3-32b (alias "fast") leaks <think> tags and takes 8s.
            "model": "gemini-2.5-flash",
            "temperature": 0.3,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var rewriteData: Data?
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return text }
            if http.statusCode == 401 {
                // Fix #1: rewriteWithKyma was silently returning raw text on 401,
                // masking a revoked key. Surface the same sign-out path as transcription.
                NSLog("[Haynoi] 401 from rewrite endpoint — key revoked, signing out")
                await MainActor.run { AuthState.shared.handleKeyRevoked() }
                NotificationHelper.postSessionExpired()
                throw STTError.sessionExpired
            }
            if http.statusCode == 429 {
                let delay = pow(2.0, Double(attempt + 1))
                NSLog("[Haynoi] Rate limited (rewrite), retrying in %.0fs (%d/3)", delay, attempt + 1)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            guard http.statusCode == 200 else {
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                NSLog("[Haynoi] Rewrite failed (%d): %@ — using raw transcription", http.statusCode, rawBody)
                return text
            }
            rewriteData = data
            break
        }
        guard let data = rewriteData else { return text }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return text
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - WAV Encoder

    private static func createWAV(samples: [Float], sampleRate: Int) throws -> Data {
        let float32Format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!

        let buffer = AVAudioPCMBuffer(pcmFormat: float32Format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i]
        }

        let int16Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("haynoi_\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: tmpURL, settings: int16Settings)
        try file.write(from: buffer)
        let data = try Data(contentsOf: tmpURL)
        try? FileManager.default.removeItem(at: tmpURL)
        return data
    }
}

// MARK: - Data Extension

private extension Data {
    mutating func append(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}

// MARK: - Errors

enum STTError: LocalizedError {
    case notSignedIn
    /// API key was valid but has been revoked server-side (HTTP 401).
    case sessionExpired
    /// Account has no remaining credits (HTTP 402).
    case outOfCredits
    /// Request was rate-limited (HTTP 429).
    case rateLimited
    /// No network connectivity (URLError transport failure).
    case noConnection
    /// Non-200/401/402/429 API response with human-readable detail.
    case serverError(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in — Settings (⌘,) → Sign in"
        case .sessionExpired:
            return "Session expired — please sign in again"
        case .outOfCredits:
            return "Out of credits — if you just signed up, verify your email to unlock your free credit, or top up at kymaapi.com."
        case .rateLimited:
            return "Servers are busy — try again in a moment"
        case .noConnection:
            return "No connection — your recording wasn't transcribed"
        case .serverError(let msg):
            return msg
        case .parseError:
            return "Something went wrong on our end — try again"
        }
    }
}
