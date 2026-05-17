import AVFoundation
import Foundation

// MARK: - STT Provider

enum STTProvider {
    /// Transcribe 16kHz mono Float32 samples using OpenAI gpt-4o-transcribe.
    static func transcribe(_ samples: [Float]) async throws -> String {
        let apiKey = UserDefaults.standard.string(forKey: "openaiApiKey") ?? ""
        guard !apiKey.isEmpty else {
            throw STTError.noApiKey
        }

        let mode = TranscriptionMode.current.resolved
        let wavData = try createWAV(samples: samples, sampleRate: 16000)
        let prompt = CustomDictionary.promptFragment + mode.sttPrompt
        var text = try await callOpenAI(apiKey: apiKey, wavData: wavData, prompt: prompt)

        // Post-process with GPT-4o if mode requires rewrite
        if mode.needsRewrite, !text.isEmpty {
            text = try await rewriteWithGPT(apiKey: apiKey, text: text, systemPrompt: mode.rewritePrompt)
        }

        return text
    }

    // MARK: - OpenAI API

    private static func callOpenAI(apiKey: String, wavData: Data, prompt: String) async throws -> String {
        let boundary = UUID().uuidString
        let model = "gpt-4o-mini-transcribe-2025-12-15"
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // file
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n")

        // model
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model)\r\n")

        // prompt
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
        body.append("\(prompt)\r\n")

        // language hint — Vietnamese primary (handles English mixed in)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        body.append("vi\r\n")

        body.append("--\(boundary)--\r\n")
        request.httpBody = body

        // Retry with exponential backoff on rate limit (429)
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

    // MARK: - GPT-4o Rewrite

    private static func rewriteWithGPT(apiKey: String, text: String, systemPrompt: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "temperature": 0.3,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Retry with backoff on rate limit
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
        guard let data = rewriteData else {
            NSLog("[Haynoi] Rewrite rate limited after 3 attempts, using raw transcription")
            return text
        }

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
        // AVAudioFile.write(from:) requires buffer in the *processing* format
        // (Float32 by default). AVAudioFile handles conversion to Int16 on disk.
        let float32Format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!

        let buffer = AVAudioPCMBuffer(pcmFormat: float32Format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Copy samples into the buffer
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i]
        }

        // Write as Int16 WAV on disk (smaller, more reliable for OpenAI API)
        let int16Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yap_\(UUID().uuidString).wav")
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
    case networkError
    case apiError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "No OpenAI API key — add in Settings (⌘,)"
        case .networkError: return "Network error"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .parseError: return "Failed to parse response"
        }
    }
}
