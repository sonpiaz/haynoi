import AVFoundation
import Foundation

// MARK: - STT Provider
//
// All transcription routed through the haynoi-server proxy. Two quality tiers
// picked by user:
//   "quality" → gpt-4o-mini-transcribe-2025-12-15 (default — best Vi/En accuracy)
//   "fast"    → whisper-v3-turbo (cheaper, clear speech only)
//
// User must be signed in via HaynoiAuth (Google / email-password). The session
// token is sent as Bearer auth; haynoi-server proxies to Kyma and meters words.
// No BYOK — single hosted backend, single sign-in.

enum STTProvider {
    /// Transcription result. `firedIDs` are the `.replacement` rule ids that
    /// actually changed the text in `applyReplacements` — fed to v1.1 self-heal.
    struct Result {
        let text: String
        let firedIDs: [UUID]
    }

    /// Back-compat convenience: text only (retry path, diagnostics).
    static func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribeTracked(samples).text
    }

    static func transcribeTracked(_ samples: [Float]) async throws -> Result {
        guard let token = HaynoiAuth.currentToken else {
            throw STTError.notSignedIn
        }

        let mode = TranscriptionMode.current.resolved
        // Encode AAC/M4A (~5× smaller than 16-bit WAV, accuracy verified
        // identical). The upload is what stalls on congested networks (VN
        // ISPs, 2026-06-12): a ~45 KB M4A survives where a ~210 KB WAV times
        // out — the body, not the route, was the bottleneck. Falls back to
        // WAV if AAC encoding fails.
        let audio = encodeAudio(samples: samples, sampleRate: 16000)
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

        let transcribed = try await callTranscribe(
            token: token, audio: audio, model: model, prompt: prompt,
            languageHint: languageHint
        )
        var text = transcribed.text

        if mode.needsRewrite, !text.isEmpty {
            text = try await rewriteWithKyma(
                token: token, text: text, systemPrompt: mode.rewritePrompt
            )
        } else if !text.isEmpty,
                  shouldRunCorrectionPass(
                      needsRewrite: mode.needsRewrite,
                      logprobs: transcribed.logprobs?.map(\.logprob),
                      hasGrounding: PersonalDictionary.shared.hasGroundingContext
                  ) {
            // Signal E (v2 Phase 3): the model itself flagged doubt on a token,
            // so this dictation — and only this one — pays for a grounded
            // correction pass. Modes with a rewrite already get the glossary +
            // pairs there; this extends the same correction to rewrite-less
            // modes without adding LLM latency to every dictation. Failure of
            // the optional pass never fails the dictation.
            //
            // v2 Phase 4: name the doubtful words and, when one sounds like a
            // dictionary term, hand the LLM that candidate explicitly —
            // "afider" → possibly "Affitor" — instead of hoping it connects
            // the glossary to the right span on its own.
            let doubtful = Self.doubtfulWords(from: transcribed.logprobs ?? [])
            let hints = doubtful.compactMap { word -> (heard: String, candidates: [String])? in
                let candidates = PersonalDictionary.shared.phoneticCandidates(for: word)
                return candidates.isEmpty ? nil : (heard: word, candidates: candidates)
            }
            text = (try? await rewriteWithKyma(
                token: token, text: text, systemPrompt: Self.correctionPassPrompt,
                hints: hints
            )) ?? text
            // Metadata only: that the pass ran — never the text.
            await MainActor.run {
                Analytics.capture("stt_correction_pass", ["trigger": "logprobs"])
            }
        }
        // Deterministic personal-dictionary replace runs LAST — after the LLM
        // rewrite (so the rewrite can't re-mangle a term we just fixed), or in
        // its place when the mode has no rewrite. Local, on-device, never a
        // network call. See redesign/07-DICTATION-LEARNING.md §5.3.
        var firedIDs: [UUID] = []
        if !text.isEmpty {
            let tracked = PersonalDictionary.shared.applyReplacementsTracked(to: text)
            text = tracked.text
            firedIDs = tracked.firedIDs
        }
        return Result(text: text, firedIDs: firedIDs)
    }

    // MARK: - Signal E: logprob-gated correction (v2 Phase 3)

    /// A token logprob below this reads as "the model wasn't sure". Tuned from
    /// live gateway data (2026-08-29, clean clip): correct tokens sit at
    /// ~-0.0001…-0.006 while misrecognized names measured -0.25…-1.11
    /// ("Sun" -0.91, "Mand"/"ec" -0.25/-0.40, "Af"/"iter" -0.37/-1.11) — the
    /// original -1.0 caught only one of four errors. -0.3 catches all but the
    /// confidently-wrong class ("Hanoi" for "Haynoi" measured -0.006), which no
    /// confidence signal can see and the deterministic replace handles instead.
    /// Watch the `stt_correction_pass` PostHog rate for over-triggering on
    /// noisy real-world audio before tightening further.
    static let lowConfidenceLogprob: Double = -0.3

    /// True when at least one token fell below the confidence floor.
    static func hasLowConfidenceToken(_ logprobs: [Double]) -> Bool {
        logprobs.contains { $0 < lowConfidenceLogprob }
    }

    /// One transcription token with its confidence, as returned upstream.
    struct TokenLogprob {
        let token: String
        let logprob: Double
    }

    /// Reconstructs whitespace-delimited words from the token stream and
    /// returns the ones containing at least one token below the confidence
    /// floor. Tokens concatenate to the transcript; a token beginning with
    /// whitespace starts a new word (" Af" + "iter" is one word, " and"
    /// starts the next). Edge punctuation is trimmed so "Hanoi." → "Hanoi".
    static func doubtfulWords(from tokens: [TokenLogprob]) -> [String] {
        var words: [(text: String, minLogprob: Double)] = []
        var current = ""
        var currentMin = 0.0
        func flush() {
            let cleaned = current
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters)
            if !cleaned.isEmpty { words.append((cleaned, currentMin)) }
            current = ""
            currentMin = 0
        }
        for t in tokens {
            if t.token.first?.isWhitespace == true, !current.isEmpty { flush() }
            current += t.token
            currentMin = min(currentMin, t.logprob)
        }
        flush()
        return words.filter { $0.minLogprob < lowConfidenceLogprob }.map(\.text)
    }

    /// The correction pass runs only when ALL hold: the mode has no rewrite
    /// (rewrite modes already carry the glossary + pairs), the model flagged a
    /// doubtful token, and there is personal context to ground the fix — an
    /// UNgrounded LLM fix-up pass over-corrects, so no grounding means no call.
    static func shouldRunCorrectionPass(
        needsRewrite: Bool, logprobs: [Double]?, hasGrounding: Bool
    ) -> Bool {
        guard !needsRewrite, hasGrounding, let logprobs else { return false }
        return hasLowConfidenceToken(logprobs)
    }

    /// Base prompt for the correction-only pass. `rewriteSystemPrompt` places
    /// the glossary and correction pairs ABOVE this, so "the context above"
    /// resolves to exactly that grounding.
    static let correctionPassPrompt = """
        The text is a raw speech-to-text transcript. Fix misrecognized words \
        using the context above. Change nothing else — no rephrasing, no \
        formatting, no additions or removals. Return only the corrected text.
        """

    /// Resolves the model alias from the user's quality setting. The proxy
    /// passes these verbatim to Kyma.
    private static func resolveModel() -> String {
        let quality = UserDefaults.standard.string(forKey: "sttQuality") ?? "quality"
        return quality == "quality" ? "transcribe-quality" : "transcribe"
    }

    // MARK: - haynoi-server proxy endpoints
    //
    // Single host. haynoi-server authenticates the session token, meters words,
    // and proxies to Kyma — so the client no longer needs the 3-route hedge that
    // worked around Kyma's edge. One POST, one timeout, one set of status codes.
    private static let transcribeURL = "\(HaynoiAuth.baseURL)/v1/proxy/audio/transcriptions"
    private static let rewriteURL = "\(HaynoiAuth.baseURL)/v1/proxy/chat/completions"

    // MARK: - Connection Diagnostic (user-facing "Test Connection")

    struct RouteResult: Identifiable {
        let id = UUID()
        let name: String
        let ok: Bool
        let latencyMs: Int?
        let detail: String     // "Reached in 0.4s" / "Upload stalled" / "HTTP 401"
    }

    struct ConnectionReport {
        let routes: [RouteResult]
        let verdict: String
        let anyWorked: Bool
    }

    /// Tests whether the AUDIO UPLOAD actually reaches the proxy — the real
    /// failure mode, not a tiny GET. Uploads a realistic ~35 KB M4A with an
    /// intentionally invalid model so the server reads the whole body then
    /// replies 400 "not a transcription model": proves the upload path works
    /// WITHOUT transcribing or metering a single word. Distinguishes network
    /// stalls (timeout) from auth (401), quota (402), and rate limits (429).
    static func runConnectionTest() async -> ConnectionReport {
        guard let token = HaynoiAuth.currentToken else {
            return ConnectionReport(routes: [], verdict: "You're not signed in. Open the Account tab and sign in first.", anyWorked: false)
        }

        // ~5s of low tone → realistic dictation-sized M4A (~35 KB) so the test
        // genuinely reproduces a congested upload, not a trivially small one.
        let sr = 16000
        var samples = [Float](repeating: 0, count: sr * 5)
        for i in 0..<samples.count { samples[i] = sin(2 * .pi * 220 * Float(i) / Float(sr)) * 0.2 }
        let audio = encodeAudio(samples: samples, sampleRate: sr)

        let boundary = UUID().uuidString
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.filename)\"\r\n")
        body.append("Content-Type: \(audio.mimeType)\r\n\r\n")
        body.append(audio.data)
        body.append("\r\n--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("__haynoi_diagnostic__\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: transcribeURL)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let label = "Haynoi"
        let t0 = Date()
        var result: RouteResult
        var has401 = false, has402 = false
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 400: result = RouteResult(name: label, ok: true, latencyMs: ms, detail: "Reached the server (\(ms) ms)")
            case 401: has401 = true; result = RouteResult(name: label, ok: false, latencyMs: ms, detail: "Sign-in expired (401)")
            case 402: has402 = true; result = RouteResult(name: label, ok: true, latencyMs: ms, detail: "Reached the server — out of words this month (402)")
            case 429: result = RouteResult(name: label, ok: false, latencyMs: ms, detail: "Servers busy (429) — try again")
            default:  result = RouteResult(name: label, ok: code < 500, latencyMs: ms, detail: "HTTP \(code) (\(ms) ms)")
            }
        } catch {
            result = RouteResult(name: label, ok: false, latencyMs: nil, detail: "Upload stalled / no response")
        }

        let anyWorked = result.ok
        let verdict: String
        if has401 {
            verdict = "Your sign-in expired. Open the Account tab and sign in again."
        } else if has402 {
            verdict = "You've used your free words for this month. Upgrade to Pro for unlimited dictation."
        } else if anyWorked {
            verdict = "Connection is good. Dictation should work."
        } else {
            verdict = "Your network is blocking the audio upload. Try a different Wi-Fi or your phone's hotspot — some networks throttle uploads to our servers."
        }
        return ConnectionReport(routes: [result], verdict: verdict, anyWorked: anyWorked)
    }

    private static func callTranscribe(
        token: String, audio: EncodedAudio, model: String, prompt: String,
        languageHint: String
    ) async throws -> (text: String, logprobs: [TokenLogprob]?) {
        let boundary = UUID().uuidString
        // Signal E: the quality tier supports per-token logprobs with the json
        // format. Harmless before the gateway ships the passthrough — the
        // response then simply carries no logprobs and the gate stays closed.
        // The fast tier's model has no logprobs support; it keeps the default
        // response shape.
        let wantsLogprobs = model == "transcribe-quality"

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.filename)\"\r\n")
        body.append("Content-Type: \(audio.mimeType)\r\n\r\n")
        body.append(audio.data)
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

        if wantsLogprobs {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
            body.append("json\r\n")
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"include[]\"\r\n\r\n")
            body.append("logprobs\r\n")
        }

        body.append("--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: transcribeURL)!)
        request.httpMethod = "POST"
        // 30s IDLE timeout (URLSession resets it whenever bytes move, so a
        // slow-but-progressing upload is safe). A genuine stall fails in 30s.
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw STTError.noConnection
            }
            switch http.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    throw STTError.parseError
                }
                // Per-token confidence (Signal E) — present only when the
                // gateway passes it through; absent = nil, gate stays closed.
                // Tokens are kept alongside values so Phase 4 can name the
                // doubtful WORDS, not just detect that doubt exists.
                var logprobs: [TokenLogprob]?
                if let entries = json["logprobs"] as? [[String: Any]] {
                    let values = entries.compactMap { entry -> TokenLogprob? in
                        guard let lp = entry["logprob"] as? Double else { return nil }
                        return TokenLogprob(token: (entry["token"] as? String) ?? "", logprob: lp)
                    }
                    if !values.isEmpty { logprobs = values }
                }
                return (text.trimmingCharacters(in: .whitespacesAndNewlines), logprobs)
            case 401:
                // Session expired/revoked server-side — sign out locally and notify UI.
                NSLog("[Haynoi] 401 from proxy — session expired, signing out")
                await MainActor.run { AuthState.shared.handleKeyRevoked() }
                NotificationHelper.postSessionExpired()
                throw STTError.sessionExpired
            case 402:
                NSLog("[Haynoi] 402 from proxy — monthly word quota exhausted")
                throw STTError.outOfCredits
            case 429:
                NSLog("[Haynoi] Rate limited by proxy")
                throw STTError.rateLimited
            default:
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                NSLog("[Haynoi] Transcription proxy error %d: %@", http.statusCode, rawBody)
                throw STTError.serverError(
                    parseProxyErrorMessage(data: data)
                        ?? "Something went wrong (HTTP \(http.statusCode)) — try again")
            }
        } catch let urlErr as URLError {
            NSLog("[Haynoi] Transport error: %@", urlErr.localizedDescription)
            throw STTError.noConnection
        }
    }

    /// Extracts the human-readable message from a proxy error envelope.
    /// Shape: {"error":{"message":"..."}} — same as OpenAI error format.
    /// Returns nil on parse failure so callers can substitute their own copy.
    private static func parseProxyErrorMessage(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any],
              let message = errorObj["message"] as? String,
              !message.isEmpty else {
            return nil
        }
        return message
    }

    /// Builds the rewrite pass's system prompt: the user's glossary as context,
    /// then known (wrong → right) pairs from their correction history as grounded
    /// few-shot examples, then the mode's own prompt. The pairs carry the cases
    /// soft biasing cannot fix — verified against the production models
    /// 2026-08-29: the STT prompt glossary corrected "Mandec"→"Mandeck" but
    /// could not beat the common word "Hanoi" for "Haynoi"; the pair could.
    /// The "only where it occurs / never insert elsewhere" framing is
    /// load-bearing: an UNgrounded LLM fix-up pass over-corrects, so the pairs
    /// are licensed as the only corrections. The `wrong` forms go ONLY here —
    /// never into the STT prompt, where prior-text conditioning would bias the
    /// decoder TOWARD the error. See redesign/10-DICTATION-LEARNING-V2.md.
    static func rewriteSystemPrompt(
        base: String,
        glossary: [String],
        pairs: [(wrong: String, right: String)],
        hints: [(heard: String, candidates: [String])] = []
    ) -> String {
        var sections: [String] = []
        if !glossary.isEmpty {
            sections.append(
                "The user's preferred spellings for names and terms (use these exact forms when they occur): "
                    + glossary.joined(separator: ", ") + "."
            )
        }
        if !pairs.isEmpty {
            let lines = pairs
                .map { "\"\($0.wrong)\" → \"\($0.right)\"" }
                .joined(separator: "\n")
            sections.append(
                "Known misrecognitions from this user's dictation history — when the left side appears, it was almost certainly meant as the right side:\n"
                    + lines
                    + "\nApply a correction only where the misrecognized form actually occurs; never insert these terms anywhere else."
            )
        }
        if !hints.isEmpty {
            // v2 Phase 4: doubtful spans matched phonetically against the
            // user's dictionary — a targeted hint, still the LLM's call.
            let lines = hints
                .map { "\"\($0.heard)\" → possibly \($0.candidates.joined(separator: " or "))" }
                .joined(separator: "\n")
            sections.append(
                "The transcriber was UNSURE of these words, and each sounds like a term this user actually uses — prefer the listed form when it fits the context:\n"
                    + lines
            )
        }
        sections.append(base)
        return sections.joined(separator: "\n\n")
    }

    private static func rewriteWithKyma(
        token: String, text: String, systemPrompt: String,
        hints: [(heard: String, candidates: [String])] = []
    ) async throws -> String {
        let url = URL(string: rewriteURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let system = rewriteSystemPrompt(
            base: systemPrompt,
            glossary: PersonalDictionary.shared.glossaryTerms(),
            pairs: PersonalDictionary.shared.correctionPairs(),
            hints: hints
        )

        let body: [String: Any] = [
            // Benchmarked 2026-06-10: gemini-2.5-flash 1.7s clean output;
            // qwen-3-32b (alias "fast") leaks <think> tags and takes 8s.
            "model": "gemini-2.5-flash",
            "temperature": 0.3,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": system],
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

    /// Audio bytes ready for multipart upload, with the right filename + MIME.
    struct EncodedAudio {
        let data: Data
        let filename: String
        let mimeType: String
    }

    /// Encodes recorded samples for upload. Prefers AAC/M4A (~5× smaller than
    /// 16-bit WAV) so the upload survives congested/lossy networks; falls back
    /// to WAV if AAC encoding fails for any reason (never blocks a dictation).
    static func encodeAudio(samples: [Float], sampleRate: Int) -> EncodedAudio {
        if let m4a = try? createM4A(samples: samples, sampleRate: sampleRate) {
            NSLog("[Haynoi] Upload: M4A %d KB (%d samples)", m4a.count / 1024, samples.count)
            return EncodedAudio(data: m4a, filename: "recording.m4a", mimeType: "audio/m4a")
        }
        // Fallback: uncompressed WAV.
        let wav = (try? createWAV(samples: samples, sampleRate: sampleRate)) ?? Data()
        NSLog("[Haynoi] Upload: WAV fallback %d KB", wav.count / 1024)
        return EncodedAudio(data: wav, filename: "recording.wav", mimeType: "audio/wav")
    }

    /// AAC-in-MPEG4 encode at 24 kbps mono — plenty for 16 kHz speech, and
    /// Kyma accepts M4A. AVAudioFile converts the Float32 buffer to AAC.
    private static func createM4A(samples: [Float], sampleRate: Int) throws -> Data {
        let float32Format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: float32Format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count { channelData[i] = samples[i] }

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24000,
        ]
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("haynoi_\(UUID().uuidString).m4a")
        // Scope the file so it deinits (flushing the AAC trailer) BEFORE the
        // read — reading a still-open compressed file yields a truncated clip.
        do {
            let file = try AVAudioFile(forWriting: tmpURL, settings: aacSettings)
            try file.write(from: buffer)
        }
        let data = try Data(contentsOf: tmpURL)
        try? FileManager.default.removeItem(at: tmpURL)
        guard data.count > 0 else { throw STTError.parseError }
        return data
    }

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
            return "You've used your free words for this week (5,000 words). Resets Monday — Pro (unlimited) coming soon."
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
