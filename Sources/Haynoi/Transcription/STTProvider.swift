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

        // Whisper treats `prompt` as continuation CONTEXT, not instructions —
        // an all-English instruction string biases its decoder toward ENGLISH
        // output (Vietnamese speech comes back translated/garbled). Only the
        // gpt-4o transcribe family follows instructions; whisper gets
        // Vietnamese-style context + raw vocabulary instead.
        let prompt: String
        if model == "transcribe-quality" {
            prompt = CustomDictionary.promptFragment + mode.sttPrompt
        } else {
            let vocab = CustomDictionary.words.filter { !$0.isEmpty }.joined(separator: ", ")
            prompt = "Đây là đoạn nói tiếng Việt, thỉnh thoảng xen vài từ tiếng Anh."
                + (vocab.isEmpty ? "" : " Từ vựng: \(vocab).")
        }

        var text = try await callKymaTranscribe(
            apiKey: apiKey, wavData: wavData, model: model, prompt: prompt
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
        apiKey: String, wavData: Data, model: String, prompt: String
    ) async throws -> String {
        let boundary = UUID().uuidString
        let url = URL(string: "\(kymaBaseURL)/v1/audio/transcriptions")!

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
            if http.statusCode == 401 {
                throw STTError.notSignedIn
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
            if http.statusCode == 429 {
                let delay = pow(2.0, Double(attempt + 1))
                NSLog("[Haynoi] Rate limited (rewrite), retrying in %.0fs (%d/3)", delay, attempt + 1)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            guard http.statusCode == 200 else {
                NSLog("[Haynoi] Rewrite failed (%d), using raw transcription", http.statusCode)
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
    case networkError
    case apiError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in — Settings (⌘,) → Sign in"
        case .networkError: return "Network error"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .parseError: return "Failed to parse response"
        }
    }
}
