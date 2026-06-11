import AppKit
import AVFoundation
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

    // Fix #4: maximum recording duration (5 minutes).  Beyond this the API
    // will reject the audio and the buffer can become very large.
    private let maxRecordingDuration: TimeInterval = 300

    // Fix #3: silence gate threshold extracted to a named constant.
    // Future work: replace with adaptive per-session calibration.
    private let silenceRMSThreshold: Float = 0.005

    // Fix #2: error-tone auto-clear timer
    private var errorClearTimer: Timer?

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
        // Sync initial state from store
        state.hasFailedDictation = FailedDictationStore.hasAny
        NSLog("[Haynoi] Pipeline ready. AX=%d InputMon=%d",
              AXIsProcessTrusted() ? 1 : 0,
              CGPreflightListenEventAccess() ? 1 : 0)
    }

    // MARK: - Recording

    /// Step 1: Command pressed — start mic immediately (captures audio from the very start)
    private var isPreRecording = false

    func preRecording() {
        guard !state.isRecording, !isPreRecording else { return }

        // Fix #3: reject recording when mic permission has been revoked.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            NSLog("[Haynoi] Microphone access not authorized (status %d)", micStatus.rawValue)
            state.error = "Microphone access revoked — click the Haynoi icon then open System Settings"
            NotificationHelper.postMicPermissionRevoked()
            return
        }

        // Fix #5: do not start a recording into the void when secure input
        // is active (the tap can't read key events reliably).
        if state.secureInputActive {
            NSLog("[Haynoi] Secure event input is active — skipping recording")
            state.error = "Secure input field focused — switch focus and try again"
            return
        }

        // Capture target app NOW — before any Haynoi UI appears or steals focus
        TextInserter.targetApp = NSWorkspace.shared.frontmostApplication

        do {
            try recorder.startRecording()
            isPreRecording = true
        } catch {
            state.error = "Mic error: \(error.localizedDescription)"
        }
    }

    /// Step 2: 200ms passed, no other key — confirm this is a solo hold
    func confirmRecording() {
        // Fix #6: tightened guard — both conditions must hold; the original
        // `isPreRecording || !state.isRecording` was too loose and allowed
        // a second confirmRecording call to start a new timer on top of the
        // first, leaking the previous repeating timer.
        guard isPreRecording, !state.isRecording else { return }
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

        // Fix #6: always invalidate before reassigning to prevent leaking a
        // repeating timer if confirmRecording is somehow called twice.
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state.recordingDuration += 0.1

                // Fix #4: enforce 5-minute max recording duration.
                // Auto-stop and transcribe what's been captured so far.
                if self.state.recordingDuration >= self.maxRecordingDuration {
                    NSLog("[Haynoi] Max recording duration reached (%.0fs), stopping",
                          self.maxRecordingDuration)
                    self.state.status = "Max dictation length reached"
                    self.stopRecording()
                }
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

        // Fix #3: silence detection gives visible feedback instead of silently
        // discarding audio (was a hard guard with only NSLog).
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        NSLog("[Haynoi] Audio RMS: %.5f (threshold %.5f)", rms, silenceRMSThreshold)
        guard rms > silenceRMSThreshold else {
            NSLog("[Haynoi] Too quiet, skipping transcription")
            setTransientError("No speech detected")
            if UserDefaults.standard.bool(forKey: "soundEnabled") {
                SoundFeedback.shared.playErrorTone()
            }
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
                let dur = Double(samples.count) / 16000.0
                UsageTracker.recordTranscription(wordCount: wordCount, durationSeconds: dur)
            } catch {
                state.isTranscribing = false
                // Fix #2: on final failure, persist WAV + error tone + notification.
                // Show a human-readable message in state.error; raw detail goes to NSLog.
                NSLog("[Haynoi] Transcription error (detail): %@", error.localizedDescription)
                handleTranscriptionFailure(samples: samples, error: error)
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
        // Fix #6: invalidate timer + reset recordingStartTime
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
        // Fix #6: play cancel tone (was never called)
        if UserDefaults.standard.bool(forKey: "soundEnabled") {
            SoundFeedback.shared.playCancelTone()
        }
    }

    // MARK: - Failure Recovery (Fix #2)

    private func handleTranscriptionFailure(samples: [Float], error: Error) {
        // Persist WAV
        if let savedURL = FailedDictationStore.save(samples: samples) {
            NSLog("[Haynoi] Failed dictation saved: %@", savedURL.path)
        }
        state.hasFailedDictation = FailedDictationStore.hasAny

        // Play error tone
        if UserDefaults.standard.bool(forKey: "soundEnabled") {
            SoundFeedback.shared.playErrorTone()
        }

        // Human-readable state message (raw detail already in NSLog above)
        state.error = "Couldn't transcribe — recording saved. Retry from the menu."

        // System notification so the user sees it even in another app
        NotificationHelper.postFailedDictation()
    }

    /// Re-runs transcription on the newest persisted failed WAV and inserts
    /// the result. Wired to the "Retry Last Dictation" menu item and to the
    /// notification action handler in AppDelegate.
    func retryLastFailedDictation() {
        guard let samples = FailedDictationStore.loadNewest() else {
            NSLog("[Haynoi] retryLastFailedDictation: no saved recording found")
            return
        }
        NSLog("[Haynoi] Retrying last failed dictation (%d samples)", samples.count)
        state.isTranscribing = true
        state.error = nil

        Task {
            do {
                let text = try await STTProvider.transcribe(samples)
                guard !text.isEmpty else {
                    state.isTranscribing = false
                    return
                }
                let finalText = SnippetManager.applySnippets(to: text)
                NSLog("[Haynoi] Retry succeeded: %@", finalText)
                state.isTranscribing = false
                state.addTranscription(finalText)
                await TextInserter.insert(finalText)
                // Clear the failed indicator since retry succeeded
                state.hasFailedDictation = FailedDictationStore.hasAny
                let wordCount = finalText.split(separator: " ").count
                let dur = Double(samples.count) / 16000.0
                UsageTracker.recordTranscription(wordCount: wordCount, durationSeconds: dur)
            } catch {
                state.isTranscribing = false
                NSLog("[Haynoi] Retry also failed: %@", error.localizedDescription)
                state.error = "Retry failed — check your connection and try again."
                if UserDefaults.standard.bool(forKey: "soundEnabled") {
                    SoundFeedback.shared.playErrorTone()
                }
            }
        }
    }

    // MARK: - Helpers

    /// Sets state.error and schedules an auto-clear after ~4s.
    private func setTransientError(_ message: String) {
        state.error = message
        errorClearTimer?.invalidate()
        errorClearTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                // Only clear if the same message is still showing
                if self?.state.error == message {
                    self?.state.error = nil
                }
            }
        }
    }
}
