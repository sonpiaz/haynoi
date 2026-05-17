import AVFoundation
import Foundation

// MARK: - STT Provider
//
// Two paths:
//   1. Hosted (default) — Bearer kyma-xxx → kymaapi.com/v1/audio/transcriptions
//                         Default model: whisper-v3-turbo (Groq Whisper, $0.04/hr)
//   2. BYOK — Bearer sk-xxx → api.openai.com/v1/audio/transcriptions
//             Default model: gpt-4o-mini-transcribe-2025-12-15 ($0.36/hr)
//
// Mode toggled via UserDefaults key "transcriptionMode" ("hosted" | "byok").
// Default: "hosted" if KymaAuth.isSignedIn, else "byok".

enum STTProvider {
    static func transcribe(_ samples: [Float]) async throws -> String {
        let mode = TranscriptionMode.current.resolved
        let wavData = try createWAV(samples: samples, sampleRate: 16000)
        let prompt = CustomDictionary.promptFragment + mode.sttPrompt

        let useHosted = resolveUseHosted()
        var text: String

        if useHosted {
            guard let kymaKey = KymaAuth.currentApiKey else {
                throw STTError.notSignedIn
            }
            text = try await callKyma(apiKey: kymaKey, wavData: wavData, prompt: prompt)

            if mode.needsRewrite, !text.isEmpty {
                text = try await rewriteWithKyma(apiKey: kymaKey, text: text, systemPrompt: mode.rewritePrompt)
            }
        } else {
            let openaiKey = UserDefaults.standard.string(forKey: "openaiApiKey") ?? ""
            guard !openaiKey.isEmpty else {
                throw STTError.noApiKey
            }
            text = try await callOpenAI(apiKey: openaiKey, wavData: wavData, prompt: prompt)

            if mode.needsRewrite, !text.isEmpty {
                text = try await rewriteWithOpenAI(apiKey: openaiKey, text: text, systemPrompt: mode.rewritePrompt)
            }
        }

        return text
    }

    /// "hosted" if user explicitly chose hosted OR (no explicit choice + signed in to Kyma).
    /// "byok" otherwise.
    private static func resolveUseHosted() -> Bool {
        let saved = UserDefaults.standard.string(forKey: "sttBackend")
        switch saved {
        case "hosted": return true
        case "byok": return false
        default: return KymaAuth.isSignedIn  // first-launch default
        }
    }

    // MARK: - Kyma API (Hosted)

    private static func callKyma(apiKey: String, wavData: Data, prompt: String) async throws -> String {
        let model = "whisper-v3-turbo"  // Groq Whisper via Kyma, cheap + fast
        let url = URL(string: "https://kymaapi.com/v1/audio/transcriptions")!
        return try await callTranscriptionAPI(
            url: url, apiKey: apiKey, model: model, wavData: wavData, prompt: prompt
        )
    }

    private static func rewriteWithKyma(apiKey: String, text: String, systemPrompt: String) async throws -> String {
        let url = URL(string: "https://kymaapi.com/v1/chat/completions")!
        return try await callChatAPI(
            url: url, apiKey: apiKey, model: "gpt-4o-mini",
            systemPrompt: systemPrompt, userText: text
        )
    }

    // MARK: - OpenAI API (BYOK)

    private static func callOpenAI(apiKey: String, wavData: Data, prompt: String) async throws -> String {
        let model = "gpt-4o-mini-transcribe-2025-12-15"
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        return try await callTranscriptionAPI(
            url: url, apiKey: apiKey, model: model, wavData: wavData, prompt: prompt
        )
    }

    private static func rewriteWithOpenAI(apiKey: String, text: String, systemPrompt: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        return try await callChatAPI(
            url: url, apiKey: apiKey, model: "gpt-4o-mini",
            systemPrompt: systemPrompt, userText: text
        )
    }

    // MARK: - Shared multipart transcription call (OpenAI-compatible)

    private static func callTranscriptionAPI(
        url: URL, apiKey: String, model: String, wavData: Data, prompt: String
    ) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
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

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
        body.append("\(prompt)\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        body.append("vi\r\n")

        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        var lastError: Error = STTError.networkError
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw STTError.networkError
            }
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    .flatMap(Double.init) ?? pow(2.0, Double(attempt + 1))
                let delay = min(retryAfter, 30.0)
                NSLog("[Haynoi] Rate limited (transcription), retrying in %.0fs (%d/3)", delay, attempt + 1)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = STTError.apiError(429, "Rate limited")
                continue
            }
            guard http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "Unknown"
                throw STTError.apiError(http.statusCode, msg)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                throw STTError.parseError
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw lastError
    }

    // MARK: - Shared chat completion call (OpenAI-compatible)

    private static func callChatAPI(
        url: URL, apiKey: String, model: String, systemPrompt: String, userText: String
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var rewriteData: Data?
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return userText }
            if http.statusCode == 429 {
                let delay = pow(2.0, Double(attempt + 1))
                NSLog("[Haynoi] Rate limited (rewrite), retrying in %.0fs (%d/3)", delay, attempt + 1)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            guard http.statusCode == 200 else {
                NSLog("[Haynoi] Rewrite failed (%d), using raw transcription", http.statusCode)
                return userText
            }
            rewriteData = data
            break
        }
        guard let data = rewriteData else {
            NSLog("[Haynoi] Rewrite rate limited after 3 attempts, using raw transcription")
            return userText
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return userText
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
    case noApiKey
    case notSignedIn
    case networkError
    case apiError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "No OpenAI API key — add in Settings (⌘,) or sign in to Kyma"
        case .notSignedIn: return "Not signed in — Settings (⌘,) → Sign in to Kyma"
        case .networkError: return "Network error"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .parseError: return "Failed to parse response"
        }
    }
}
