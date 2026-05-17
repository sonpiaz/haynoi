import AppKit
import Combine

/// Connects HotkeyManager → AudioRecorder → STT → TextInserter.
/// All methods run on @MainActor.
@MainActor
final class PipelineController {
    static let shared = PipelineController()

    private let recorder = AudioRecorder.shared
    private let state = AppState.shared
    private var durationTimer: Timer?
    private var levelCancellable: AnyCancellable?
    private var recordingStartTime: Date?
    private let minimumDuration: TimeInterval = 0.3

    private init() {
        // Bridge AudioRecorder.audioLevel → AppState.audioLevel
        levelCancellable = recorder.$audioLevel
            .receive(on: RunLoop.main)
            .assign(to: \.audioLevel, on: state)
    }

    // MARK: - Setup

    func setup() {
        let hotkey = HotkeyManager.shared
        hotkey.onModifierDown = { [weak self] in
            // Start buffering audio immediately (before 200ms grace period)
            Task { @MainActor in self?.preRecording() }
        }
        hotkey.onKeyDown = { [weak self] in
            // Grace period passed — confirm recording
            Task { @MainActor in self?.confirmRecording() }
        }
        hotkey.onKeyUp = { [weak self] in
            Task { @MainActor in self?.stopRecording() }
        }
        hotkey.onCancelled = { [weak self] in
            // Cmd+C/V detected — cancel pre-recording
            Task { @MainActor in self?.cancelRecording() }
        }
        hotkey.start()
        NSLog("[Haynoi] Pipeline ready. AX=%d InputMon=%d",
              AXIsProcessTrusted() ? 1 : 0,
              CGPreflightListenEventAccess() ? 1 : 0)
    }

    // MARK: - Recording

    /// Step 1: Command pressed — start mic immediately (captures audio from the very start)
    private var isPreRecording = false

    func preRecording() {
        guard !state.isRecording, !isPreRecording else { return }

        // Capture target app NOW — before any Haynoi UI appears or steals focus
        TextInserter.targetApp = NSWorkspace.shared.frontmostApplication

        do {
            try recorder.startRecording()
            isPreRecording = true
        } catch {
            state.error = "Mic error: \(error.localizedDescription)"
        }
    }

    /// Step 2: 500ms passed, no other key — confirm this is a solo hold
    func confirmRecording() {
        guard isPreRecording || !state.isRecording else { return }
        isPreRecording = false

        // If preRecording didn't start (no mic), try now
        if recorder.isRunning == false {
            do { try recorder.startRecording() } catch {
                state.error = "Mic error: \(error.localizedDescription)"
                return
            }
        }

        state.isRecording = true
        state.showOverlay = true
        state.recordingDuration = 0
        FloatingBarController.shared.show()
        MediaController.pauseIfPlaying()
        state.error = nil
        recordingStartTime = Date()

        if UserDefaults.standard.bool(forKey: "soundEnabled") {
            SoundFeedback.shared.playStartTone()
        }

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state.recordingDuration += 0.1
            }
        }
    }

    func stopRecording() {
        guard state.isRecording else { return }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil
        durationTimer?.invalidate()
        durationTimer = nil

        let samples = recorder.stopRecording()

        // Hide floating bar BEFORE state changes to avoid
        // SwiftUI teardown racing with @Published updates
        FloatingBarController.shared.hide()
        state.isRecording = false
        state.showOverlay = false
        MediaController.resumeIfPaused()

        // Too short — cancel
        if duration < minimumDuration {
            NSLog("[Haynoi] Recording too short (%.2fs), cancelled", duration)
            return
        }

        // Need at least 0.5s of audio (8000 samples at 16kHz)
        guard samples.count > 8000 else {
            state.error = "Too short to transcribe"
            return
        }

        // Silence detection — skip if audio is too quiet (no speech)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        NSLog("[Haynoi] Audio RMS: %.5f", rms)
        guard rms > 0.005 else {
            NSLog("[Haynoi] Too quiet, skipping transcription")
            return
        }

        if UserDefaults.standard.bool(forKey: "soundEnabled") {
            SoundFeedback.shared.playStopTone()
        }

        NSLog("[Haynoi] Transcribing %d samples (%.1fs)", samples.count, Float(samples.count) / 16000)
        state.isTranscribing = true

        Task {
            do {
                let text = try await STTProvider.transcribe(samples)
                guard !text.isEmpty else {
                    state.isTranscribing = false
                    return
                }
                // Apply snippets
                let finalText = SnippetManager.applySnippets(to: text)
                NSLog("[Haynoi] Transcribed: %@", finalText)
                state.isTranscribing = false
                state.addTranscription(finalText)
                await TextInserter.insert(finalText)
                let wordCount = text.split(separator: " ").count
                let duration = Double(samples.count) / 16000.0
                UsageTracker.recordTranscription(wordCount: wordCount, durationSeconds: duration)
            } catch {
                state.isTranscribing = false
                state.error = error.localizedDescription
                NSLog("[Haynoi] Transcription error: %@", error.localizedDescription)
            }
        }
    }

    func cancelRecording() {
        if isPreRecording {
            _ = recorder.stopRecording()
            isPreRecording = false
        }
        guard state.isRecording else { return }
        _ = recorder.stopRecording()
        state.isRecording = false
        state.showOverlay = false
        FloatingBarController.shared.hide()
        MediaController.resumeIfPaused()
        durationTimer?.invalidate()
        durationTimer = nil
    }
}
