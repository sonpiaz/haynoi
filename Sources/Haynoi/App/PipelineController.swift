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

    // Retained for legacy call-sites; actual clear is now in AppState.setTransientError
    private var errorClearTimer: Timer?

    // Fix #9: active insertion task — serializes insertions so dictation N+1
    // waits for N's insertion to finish (prevents targetApp static race).
    private var activeInsertion: Task<Void, Never>?

    // Fix #10: delay before actually starting the audio engine.
    // Bare Cmd presses (Cmd+C, Cmd+Tab) release within 90ms and should NEVER
    // spin up the microphone — that reads as spyware.
    private static let preRecordingEngineDelayNs: UInt64 = 90_000_000 // 90ms

    // Fix #10: task handle for the delayed engine-start, so it can be cancelled
    // if the key is released or a chord is detected before the delay elapses.
    private var preRecordingDelayTask: Task<Void, Never>?

    // Fix #5 (AudioRecorder): observer for self-abort notifications.
    private var abortObserver: NSObjectProtocol?

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

        // Fix #5: observe AudioRecorder self-abort (device failure mid-recording).
        abortObserver = NotificationCenter.default.addObserver(
            forName: AudioRecorder.didAbortRecording,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?["reason"] as? String ?? "Recording error"
            Task { @MainActor in self?.handleRecorderAbort(reason) }
        }

        // Sync initial state from store
        state.hasFailedDictation = FailedDictationStore.hasAny
        NSLog("[Haynoi] Pipeline ready. AX=%d InputMon=%d",
              AXIsProcessTrusted() ? 1 : 0,
              CGPreflightListenEventAccess() ? 1 : 0)
    }

    // MARK: - Recording

    /// Step 1: Command pressed — schedule mic start after a short delay.
    /// Fix #10: actual engine start is deferred 90ms so bare Cmd presses (chords)
    /// never spin up the microphone. The pre-buffer semantics survive for real holds.
    private var isPreRecording = false

    func preRecording() {
        guard !state.isRecording, !isPreRecording else { return }

        // Fix #3: reject recording when mic permission has been revoked.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            NSLog("[Haynoi] Microphone access not authorized (status %d)", micStatus.rawValue)
            state.setTransientError("Microphone access revoked — click the Haynoi icon then open System Settings")
            NotificationHelper.postMicPermissionRevoked()
            return
        }

        // Fix #5: do not start a recording into the void when secure input
        // is active (the tap can't read key events reliably).
        if state.secureInputActive {
            NSLog("[Haynoi] Secure event input is active — skipping recording")
            state.setTransientError("Secure input field focused — switch focus and try again")
            return
        }

        // Capture target app NOW — before any Haynoi UI appears or steals focus.
        // Fix #9: stored locally; will be passed through to insert() explicitly.
        let capturedTargetApp = NSWorkspace.shared.frontmostApplication

        // Fix #10: delay actual engine start by 90ms. Chord releases < 90ms skip audio.
        isPreRecording = true
        preRecordingDelayTask = Task {
            try? await Task.sleep(nanoseconds: PipelineController.preRecordingEngineDelayNs)
            guard !Task.isCancelled else {
                NSLog("[Haynoi] pre-recording delay cancelled (chord or fast release)")
                return
            }
            await MainActor.run {
                self.startEngineForPreRecording(capturedTargetApp: capturedTargetApp)
            }
        }
    }

    /// Called after the 90ms chord-filter delay to actually start the audio engine.
    private func startEngineForPreRecording(capturedTargetApp: NSRunningApplication?) {
        guard isPreRecording, !state.isRecording else { return }
        // Store target app for this dictation (Fix #9: per-dictation, not static).
        currentDictationTargetApp = capturedTargetApp
        do {
            try recorder.startRecording()
        } catch {
            isPreRecording = false
            state.setTransientError("Mic error: \(error.localizedDescription)")
        }
    }

    // Fix #9: per-dictation target app — set in preRecording, consumed in stopRecording.
    private var currentDictationTargetApp: NSRunningApplication?

    /// Step 2: 200ms passed, no other key — confirm this is a solo hold
    func confirmRecording() {
        // Fix #6: tightened guard — both conditions must hold; the original
        // `isPreRecording || !state.isRecording` was too loose and allowed
        // a second confirmRecording call to start a new timer on top of the
        // first, leaking the previous repeating timer.
        guard isPreRecording, !state.isRecording else { return }
        isPreRecording = false

        // If engine hasn't started yet (pre-recording delay still in flight),
        // cancel the delay task and start immediately now.
        preRecordingDelayTask?.cancel()
        preRecordingDelayTask = nil

        if recorder.isRunning == false {
            do { try recorder.startRecording() } catch {
                state.setTransientError("Mic error: \(error.localizedDescription)")
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
                    self.state.setTransientStatus("Max dictation length reached")
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

        // Capture per-dictation target app before the next preRecording can overwrite it.
        // Fix #9: snapshot and pass through, do not use a shared static.
        let dictationTargetApp = currentDictationTargetApp

        // Transition orb to "thinking" state rather than hiding it — the orb
        // stays visible during the network round-trip so users know work is in
        // flight.  The orb will auto-hide after success/error transitions.
        FloatingBarController.shared.transition(to: .transcribing)
        state.isRecording = false
        state.showOverlay = false
        MediaController.resumeIfPaused()

        // Too short — cancel silently, just hide the orb
        if duration < minimumDuration {
            NSLog("[Haynoi] Recording too short (%.2fs), cancelled", duration)
            FloatingBarController.shared.hide()
            return
        }

        // Need at least 0.5s of audio (8000 samples at 16kHz)
        guard samples.count > 8000 else {
            FloatingBarController.shared.transition(to: .error)
            state.setTransientError("Too short to transcribe")
            return
        }

        // Fix #3: silence detection gives visible feedback
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        NSLog("[Haynoi] Audio RMS: %.5f (threshold %.5f)", rms, silenceRMSThreshold)
        guard rms > silenceRMSThreshold else {
            NSLog("[Haynoi] Too quiet, skipping transcription")
            FloatingBarController.shared.transition(to: .error)
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

        // Fix #9: serialize insertions — wait for any in-flight insertion to complete
        // before starting the new one. Recording is NOT blocked (samples are captured);
        // only the text-insertion step serializes.
        let previousInsertion = activeInsertion
        activeInsertion = Task {
            // Wait for the previous insertion to finish first.
            await previousInsertion?.value

            do {
                let text = try await STTProvider.transcribe(samples)
                guard !text.isEmpty else {
                    await MainActor.run { state.isTranscribing = false }
                    return
                }
                // Apply snippets
                let finalText = SnippetManager.applySnippets(to: text)
                NSLog("[Haynoi] Transcribed: %@", finalText)
                // Capture attribution from the dictation target app (F2.3 / D17).
                let attrBundleId = dictationTargetApp?.bundleIdentifier
                let attrAppName = dictationTargetApp?.localizedName
                await MainActor.run {
                    state.isTranscribing = false
                    state.addTranscription(finalText,
                                           appBundleId: attrBundleId,
                                           appName: attrAppName)
                    // Orb: success flash then auto-hide
                    FloatingBarController.shared.transition(to: .success)
                    if UserDefaults.standard.bool(forKey: "soundEnabled") {
                        SoundFeedback.shared.playSuccessTone()
                    }
                }
                // Fix #9: pass capturedTargetApp explicitly instead of mutating the static.
                await TextInserter.insert(finalText, targetApp: dictationTargetApp)
                let wordCount = text.split(separator: " ").count
                let dur = Double(samples.count) / 16000.0
                // Snapshot total BEFORE recording for milestone threshold check (D15)
                let totalBefore = UsageTracker.totalWords
                UsageTracker.recordTranscription(wordCount: wordCount, durationSeconds: dur,
                                                 appBundleId: attrBundleId,
                                                 appName: attrAppName)
                let totalAfter = UsageTracker.totalWords
                MilestoneTracker.markUnseenIfNeeded(previousTotal: totalBefore, newTotal: totalAfter)
                // Notify that a dictation completed so any open Settings panel can
                // refresh the credit balance. Posted on the main actor: SwiftUI's
                // .onReceive delivers on the posting thread.
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .haynoiDictationCompleted, object: nil
                    )
                }
            } catch {
                await MainActor.run {
                    state.isTranscribing = false
                    NSLog("[Haynoi] Transcription error (detail): %@", error.localizedDescription)
                    // Account-level errors (no credits / revoked key) are not
                    // transient: saving the WAV and offering a retry would just
                    // loop into the same failure. Surface the actionable copy.
                    // Orb: error flash then auto-hide
                    FloatingBarController.shared.transition(to: .error)
                    if let sttErr = error as? STTError,
                       case .outOfCredits = sttErr {
                        state.error = sttErr.errorDescription
                        if UserDefaults.standard.bool(forKey: "soundEnabled") {
                            SoundFeedback.shared.playErrorTone()
                        }
                        return
                    }
                    if let sttErr = error as? STTError,
                       case .sessionExpired = sttErr {
                        state.error = sttErr.errorDescription
                        if UserDefaults.standard.bool(forKey: "soundEnabled") {
                            SoundFeedback.shared.playErrorTone()
                        }
                        return
                    }
                    handleTranscriptionFailure(samples: samples, error: error)
                }
            }
        }
    }

    func cancelRecording() {
        // Fix #10: cancel delayed engine-start if key is released before delay elapses.
        preRecordingDelayTask?.cancel()
        preRecordingDelayTask = nil

        if isPreRecording {
            _ = recorder.stopRecording()
            isPreRecording = false
        }
        guard state.isRecording else { return }
        _ = recorder.stopRecording()
        state.isRecording = false
        state.showOverlay = false
        // On cancel: just hide — no success/error feedback needed
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

    // MARK: - Device Abort Handler (Fix #5)

    /// Called when AudioRecorder posts `didAbortRecording` (device failure mid-recording).
    private func handleRecorderAbort(_ reason: String) {
        NSLog("[Haynoi] Recorder aborted: %@", reason)

        // Tear down recording state without calling recorder.stopRecording()
        // (the recorder already cleaned itself up before posting the notification).
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
        isPreRecording = false

        // Show error orb briefly, then hide
        FloatingBarController.shared.transition(to: .error)
        state.isRecording = false
        state.showOverlay = false
        MediaController.resumeIfPaused()

        setTransientError(reason)
        if UserDefaults.standard.bool(forKey: "soundEnabled") {
            SoundFeedback.shared.playErrorTone()
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

        // Human-readable state message (raw detail already in NSLog above).
        // Prefer the specific STTError copy; fall back to the generic line.
        let humanCopy = (error as? STTError)?.errorDescription
        let message = humanCopy.map { "\($0) — recording saved." }
            ?? "Couldn't transcribe — recording saved. Retry from the menu."
        state.error = message

        // System notification so the user sees it even in another app
        NotificationHelper.postFailedDictation()
    }

    /// Re-runs transcription on the newest persisted failed WAV and inserts
    /// the result. Wired to the "Retry Last Dictation" menu item and to the
    /// notification action handler in AppDelegate.
    func retryLastFailedDictation() {
        // Fix #3: re-entry guard — retry must not run concurrently with itself
        // or with a live dictation.
        guard !state.isTranscribing, !state.isRecording else {
            NSLog("[Haynoi] retryLastFailedDictation: skipped (already transcribing or recording)")
            return
        }

        guard let samples = FailedDictationStore.loadNewest() else {
            NSLog("[Haynoi] retryLastFailedDictation: no saved recording found")
            return
        }
        NSLog("[Haynoi] Retrying last failed dictation (%d samples)", samples.count)
        state.isTranscribing = true
        state.error = nil

        // Fix #6: capture the frontmost app now. If it is Haynoi itself (e.g.
        // the user clicked Retry from our menu), do not try to paste — copy to
        // clipboard and show the "Press ⌘V" notification instead.
        let retryTargetApp: NSRunningApplication?
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            retryTargetApp = nil // signals clipboard-fallback below
        } else {
            retryTargetApp = frontmost
        }

        Task {
            do {
                let text = try await STTProvider.transcribe(samples)
                guard !text.isEmpty else {
                    await MainActor.run { state.isTranscribing = false }
                    return
                }
                let finalText = SnippetManager.applySnippets(to: text)
                NSLog("[Haynoi] Retry succeeded: %@", finalText)
                // Fix #2: delete the saved WAV BEFORE recomputing hasFailedDictation
                // so the Retry button disappears and a second retry cannot replay
                // the same recording.
                FailedDictationStore.deleteNewest()
                // Capture attribution from retry target app (mirrors primary path).
                let retryBundleId = retryTargetApp?.bundleIdentifier
                let retryAppName = retryTargetApp?.localizedName
                await MainActor.run {
                    state.isTranscribing = false
                    state.addTranscription(finalText,
                                           appBundleId: retryBundleId,
                                           appName: retryAppName)
                    state.hasFailedDictation = FailedDictationStore.hasAny
                }
                await TextInserter.insert(finalText, targetApp: retryTargetApp)
                let wordCount = finalText.split(separator: " ").count
                let dur = Double(samples.count) / 16000.0
                let totalBefore = UsageTracker.totalWords
                UsageTracker.recordTranscription(wordCount: wordCount, durationSeconds: dur,
                                                 appBundleId: retryBundleId,
                                                 appName: retryAppName)
                let totalAfter = UsageTracker.totalWords
                MilestoneTracker.markUnseenIfNeeded(previousTotal: totalBefore, newTotal: totalAfter)
            } catch {
                await MainActor.run {
                    state.isTranscribing = false
                    NSLog("[Haynoi] Retry also failed: %@", error.localizedDescription)
                    state.setTransientError("Retry failed — check your connection and try again.")
                    if UserDefaults.standard.bool(forKey: "soundEnabled") {
                        SoundFeedback.shared.playErrorTone()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Sets state.error with auto-clear.  Delegates to AppState's Combine-based timer.
    private func setTransientError(_ message: String) {
        state.setTransientError(message)
    }
}
