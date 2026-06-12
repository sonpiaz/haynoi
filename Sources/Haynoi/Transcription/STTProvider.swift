import AVFoundation
import Foundation

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

    private static func callKymaTranscribe(
        apiKey: String, wavData: Data, model: String, prompt: String,
        languageHint: String
    ) async throws -> String {
        let boundary = UUID().uuidString
        let url = URL(string: "\(kymaBaseURL)/v1/audio/transcriptions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Fix #2: raised from 30 → 90s — long audio or congested networks
        // were hitting the old limit and discarding the recording entirely.
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

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
        request.httpBody = body

        var lastError: Error = STTError.noConnection
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw STTError.noConnection
                }
                if http.statusCode == 401 {
                    // Key was revoked server-side — sign out locally and notify UI.
                    NSLog("[Haynoi] 401 from transcription endpoint — key revoked, signing out")
                    await MainActor.run { AuthState.shared.handleKeyRevoked() }
                    NotificationHelper.postSessionExpired()
                    throw STTError.sessionExpired
                }
                if http.statusCode == 402 {
                    // Fix #2: credit exhaustion is an expected pay-as-you-go state.
                    NSLog("[Haynoi] 402 from transcription endpoint — out of credits")
                    throw STTError.outOfCredits
                }
                if http.statusCode == 429 {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init) ?? pow(2.0, Double(attempt + 1))
                    let delay = min(retryAfter, 30.0)
                    NSLog("[Haynoi] Rate limited (transcription), retrying in %.0fs (%d/3)", delay, attempt + 1)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    lastError = STTError.rateLimited
                    continue
                }
                guard http.statusCode == 200 else {
                    // Fix #2: parse the Kyma error envelope {"error":{"message":...}}
                    // instead of dumping raw bodies. Detail stays in NSLog only.
                    let rawBody = String(data: data, encoding: .utf8) ?? ""
                    NSLog("[Haynoi] Transcription API error %d: %@", http.statusCode, rawBody)
                    let humanMessage = parseKymaErrorMessage(data: data)
                        ?? "Something went wrong on our end — try again"
                    throw STTError.serverError(humanMessage)
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    throw STTError.parseError
                }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch let urlErr as URLError {
                // Fix #2: transport errors (offline, DNS, timeout) were not
                // retried — the WAV was lost silently. The audio is in memory;
                // retrying costs nothing but a short backoff.
                let backoff = pow(2.0, Double(attempt + 1)) // 2s, 4s
                NSLog("[Haynoi] Transport error (transcription, attempt %d/3): %@ — retrying in %.0fs",
                      attempt + 1, urlErr.localizedDescription, backoff)
                lastError = STTError.noConnection
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            } catch let sttErr as STTError {
                // Non-retriable STT errors (401, 402) — propagate immediately.
                throw sttErr
            }
        }
        throw lastError
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
