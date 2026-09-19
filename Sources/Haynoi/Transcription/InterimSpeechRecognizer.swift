import Foundation
import Speech
import AVFoundation

/// On-device SFSpeechRecognizer partials while the PTT key is held.
///
/// Honest overlay only: partials live in RAM (`AppState.interimPartial`) and
/// are never persisted, inserted, or sent to the proxy. Release still uses the
/// existing batch POST to `/v1/proxy/audio/transcriptions`. If speech
/// recognition is unavailable (locale, entitlement, auth), the overlay line
/// stays empty / ellipsis — the UI slot still exists. Never a canned string.
final class InterimSpeechRecognizer {
    static let shared = InterimSpeechRecognizer()

    private let queue = DispatchQueue(label: "com.haynoi.interim-speech")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation: UInt64 = 0
    private var transcript = InterimTranscript()
    private var latestFinalText: String = ""

    private init() {}

    /// Warm the privacy prompt so the first real hold can actually stream.
    /// Safe no-op when already determined.
    func prefetchAuthorization() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { status in
            NSLog("[Haynoi] Interim SFSpeech auth: %d", status.rawValue)
        }
    }

    func start() {
        DispatchQueue.main.async {
            AppState.shared.interimPartial = ""
        }
        // Sync so the first tap buffers after confirmRecording hit a live request.
        queue.sync { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        // Keep the last partial on screen as committed (no bold) until hide /
        // the next hold. Blanking here made the caption vanish on key-up.
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    func finalText() -> String {
        queue.sync {
            latestFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Hardware-format PCM from AudioRecorder's existing tap (one tap per bus).
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.request?.append(buffer)
        }
    }

    private func startOnQueue() {
        stopOnQueue()
        transcript = InterimTranscript()
        latestFinalText = ""

        let locale = Self.preferredLocale()
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            NSLog("[Haynoi] Interim SFSpeech unavailable (locale %@)", locale.identifier)
            return
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            // Prompt, but do not pretend this hold has partials.
            SFSpeechRecognizer.requestAuthorization { status in
                NSLog("[Haynoi] Interim SFSpeech auth (mid-hold): %d", status.rawValue)
            }
            return
        default:
            NSLog("[Haynoi] Interim SFSpeech: not authorized")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Vietnamese on-device is often unavailable; still run vi-VN so the
        // orb updates as he talks. Partials stay RAM-only either way.
        let onDevice = rec.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        if #available(macOS 13.0, *) {
            // Sentence-end marks let the HUD drop bold on a finished clause.
            // Display-only — inserted text still comes from the cloud POST.
            request.addsPunctuation = true
        }

        generation += 1
        let gen = generation
        recognizer = rec
        self.request = request
        task = rec.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                if let result {
                    self.transcript.ingest(
                        result.bestTranscription.formattedString,
                        endsUtterance: result.speechRecognitionMetadata != nil
                    )
                    let text = self.transcript.text
                    self.latestFinalText = text
                    DispatchQueue.main.async {
                        AppState.shared.interimPartial = CaptionLayout.tail(text)
                    }
                }
                if let error {
                    NSLog("[Haynoi] Interim SFSpeech error: %@", error.localizedDescription)
                }
            }
        }
        NSLog("[Haynoi] Interim SFSpeech started (locale %@, onDevice=%d)", locale.identifier, onDevice ? 1 : 0)
    }

    private func stopOnQueue() {
        generation += 1
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }

    /// `auto` and `vi` lock to Vietnamese. English hint stays en-US.
    /// Never follow the Mac's en-US default — that is how English seeds appeared.
    private static func preferredLocale() -> Locale {
        switch UserDefaults.standard.string(forKey: "languageHint") ?? "auto" {
        case "en": return Locale(identifier: "en-US")
        default: return Locale(identifier: "vi-VN")
        }
    }
}

/// Every partial of one PTT hold. Still shows only the latest partial.
struct InterimTranscript {
    private(set) var text = ""

    mutating func ingest(_ partial: String, endsUtterance: Bool) {
        guard !partial.isEmpty else { return }
        text = partial
    }
}
