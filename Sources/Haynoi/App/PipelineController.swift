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

    // Pre-roll duration spliced into the recording at confirmRecording. Covers
    // the 200ms grace period + the user's reaction time so first words are never
    // lost, even on a cold Bluetooth mic.
    private static let preRollMs = 300

    // Fix #5 (AudioRecorder): observer for self-abort notifications.
    private var abortObserver: NSObjectProtocol?

    // v1.1 — auto-disarm "fix that" if no dictation follows within ~10s.
    private var correctionDisarmTimer: Timer?

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
        // v1.1 — "fix that" gesture arms correction mode for the next dictation.
        hotkey.onFixThat = { [weak self] in
            Task { @MainActor in self?.armCorrection() }
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

        // If a previous session died mid-dictation with the output volume
        // ducked, put it back before the user notices a quiet Mac.
        MediaController.repairAfterCrash()

        // Sync initial state from store
        state.hasFailedDictation = FailedDictationStore.hasAny
        // Accessibility gates both text insertion and the NSEvent hotkey
        // monitors, so it is the only permission worth logging now.
        NSLog("[Haynoi] Pipeline ready. AX=%d",
              AXIsProcessTrusted() ? 1 : 0)

        // Warm the engine once on launch if mic permission is already granted so
        // the very first dictation is also instant. The 60s cooldown releases the
        // mic shortly after if the user doesn't dictate right away.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            recorder.ensureWarm()
            recorder.endCapture() // schedules cooldown without capturing
        }
    }

    // MARK: - Recording

    /// Step 1: Modifier pressed (t=0) — warm the audio engine IMMEDIATELY.
    /// The engine starts in ring-buffer mode (no capture yet), so warming on a
    /// chord is harmless: the cooldown reclaims the mic if the press doesn't
    /// become a real hold. This kills the cold-start delay (50–300ms built-in,
    /// 1–3s Bluetooth) so capture is live the instant the grace period passes.
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
        currentDictationTargetApp = capturedTargetApp

        // Warm the engine right now (ring-buffer mode, off the main actor).
        isPreRecording = true
        recorder.ensureWarm()
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

        // Begin capture: splice the last preRollMs of ring buffer into the
        // recording so the 200ms grace + reaction time is never lost, then
        // switch the tap to record mode. ensureWarm() inside beginCapture is a
        // no-op when the engine is already warm from preRecording().
        // Play the start tone ONLY when capture actually goes live (first live
        // tap buffer). When warm this fires within ~1 frame, so the cue is both
        // honest (mic is truly capturing) AND fast. Registered BEFORE
        // beginCapture so the very first live buffer can consume it.
        if UserDefaults.standard.bool(forKey: "soundEnabled") {
            recorder.onCaptureLive {
                SoundFeedback.shared.playStartTone()
            }
        }

        recorder.beginCapture(preRollMs: PipelineController.preRollMs)

        state.isRecording = true
        state.showOverlay = true
        state.recordingDuration = 0
        FloatingBarController.shared.show()
        MediaController.pauseIfPlaying()
        state.error = nil
        recordingStartTime = Date()

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

        recordingStartTime = nil
        durationTimer?.invalidate()
        durationTimer = nil

        let samples = recorder.endCapture()

        // Measure duration from the actual captured samples (pre-roll included)
        // rather than wall-clock from confirmRecording: this is what the user
        // actually said, and it stays correct even if the start tone was slightly
        // late on a cold mic.
        let duration = Double(samples.count) / 16000.0

        // Fix #5: the pre-roll (preRollMs) is spliced into the buffer at
        // beginCapture, so even a near-instant release yields ~preRollMs of audio.
        // Gate the minimum-duration check on the user's ACTUAL hold time (total
        // captured minus the pre-roll) so a 0ms hold + 300ms pre-roll does not
        // sneak past as "speech" and burn an STT API call on non-speech audio.
        let actualDuration = max(0, duration - Double(PipelineController.preRollMs) / 1000.0)

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

        // Too short — cancel silently, just hide the orb. Gate on actualDuration
        // (pre-roll removed) so a tap that captured only pre-roll is dropped.
        if actualDuration < minimumDuration {
            NSLog("[Haynoi] Recording too short (%.2fs actual, %.2fs total), cancelled",
                  actualDuration, duration)
            FloatingBarController.shared.hide()
            return
        }

        // Secondary guard: need at least 0.5s of REAL speech on top of the
        // pre-roll. 8000 samples (0.5s) + the pre-roll padding (preRollMs).
        let minSamples = 8000 + (PipelineController.preRollMs * 16000) / 1000
        guard samples.count > minSamples else {
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
                let result = try await STTProvider.transcribeTracked(samples)
                let text = result.text
                guard !text.isEmpty else {
                    await MainActor.run { state.isTranscribing = false }
                    return
                }

                // v1.1 — if "fix that" is armed, this dictation is the CORRECTED
                // version of the last one. Route it through the correction path
                // and SKIP the normal addTranscription/insert success path so the
                // corrected text is inserted exactly once (no double-insert).
                if await MainActor.run(body: { state.isCorrectionArmed }) {
                    await MainActor.run {
                        state.isTranscribing = false
                        state.isCorrectionArmed = false
                        correctionDisarmTimer?.invalidate()
                        correctionDisarmTimer = nil
                    }
                    await handleCorrection(correctedTranscript: text)
                    return
                }

                // Apply snippets
                let finalText = SnippetManager.applySnippets(to: text)
                NSLog("[Haynoi] Transcribed: %@", finalText)
                // Capture attribution from the dictation target app (F2.3 / D17).
                let attrBundleId = dictationTargetApp?.bundleIdentifier
                let attrAppName = dictationTargetApp?.localizedName
                let dictWordCount = finalText.split(whereSeparator: \.isWhitespace).count
                await MainActor.run {
                    state.isTranscribing = false
                    state.addTranscription(finalText,
                                           appBundleId: attrBundleId,
                                           appName: attrAppName)
                    // Orb: "N words" success chip then auto-hide. The optional
                    // dink is quieter and tonally distinct from the stop tone
                    // (founder pick from the 2026-06-12 sound contest) and can
                    // be turned off in Settings → Sounds.
                    state.lastDictationWordCount = dictWordCount
                    FloatingBarController.shared.transition(to: .success)
                    let defaults = UserDefaults.standard
                    if defaults.bool(forKey: "soundEnabled"),
                       defaults.bool(forKey: "successDinkEnabled") {
                        SoundFeedback.shared.playSuccessTone()
                    }
                }
                // Fix #9: pass capturedTargetApp explicitly instead of mutating the static.
                let insertResult = await TextInserter.insert(finalText, targetApp: dictationTargetApp)
                // v1.1 — record what/where the last dictation landed so a "fix
                // that" can replace it in place and learn from the diff. Keep
                // lastTranscript = raw STT text (not finalText): snippets/replaces
                // are deterministic and shouldn't be "learned"; diffing the raw
                // transcript isolates the genuine recognition error.
                // v1.2 — Signal B (re-dictation similarity). Compare this transcript
                // to the previous one (RAM-only) BEFORE overwriting lastTranscript.
                // A qualifying near-homophone re-dictation opportunistically SUGGESTS
                // learning the corrected word as a SOFT-BIAS .term — never a
                // .replacement (low confidence, can't corrupt output). Suggest-never-
                // silent: the toast only adds on tap, suppressed in live contexts.
                await MainActor.run {
                    if let s = CorrectionDetector.shared.observe(text),
                       !LiveContext.isActive() {
                        let right = s.right
                        FloatingBarController.shared.showLearnToast(
                            wrong: s.wrong, right: right,
                            onRemember: {
                                // SOFT-BIAS ONLY: .term (source .learned), NEVER a
                                // .replacement. The .term feeds the prompt/rewrite
                                // glossary; it can never trigger a hard swap.
                                _ = PersonalDictionary.shared.addTerm(right, source: .learned)
                                NSLog("[Haynoi] Learned (re-dictation, term-only): %@", right)
                                // Metadata only: just which detector fired — never the term string.
                                Analytics.capture("dictionary_term_learned", ["signal": "redictation"])
                            },
                            onIgnore: {}
                        )
                    }
                }
                await MainActor.run {
                    state.lastTranscript = text
                    state.lastInsertedText = insertResult.inserted
                    state.lastTargetApp = insertResult.targetApp ?? dictationTargetApp
                    state.lastInsertionSpan = insertResult.span
                    state.lastDictationAt = Date()
                    state.lastFiredRuleIDs = result.firedIDs

                    // Product analytics — metadata only. `words` is the count;
                    // `mode` is the TranscriptionMode enum; `target_app_bundle` is
                    // the frontmost app's bundle ID (an app identifier, NOT content).
                    // NEVER pass `text`/`finalText`.
                    Analytics.capture("dictation_inserted", [
                        "words": dictWordCount,
                        "mode": UserDefaults.standard.string(forKey: "transcriptionMode") ?? "Normal",
                        "target_app_bundle": attrBundleId ?? "unknown",
                    ])

                    // v1.3 — Signal A (AX read-back of in-place edits). Flush the
                    // PREVIOUS anchor first (the "edit then dictate again" flow),
                    // then arm a new anchor for THIS insertion. Arm only when AX
                    // gave a real span (nil span = Electron/browser → never arms)
                    // and the app is AX-cooperative (CorrectionWatcher gates both).
                    CorrectionWatcher.shared.reRead(reason: .nextDictation)
                    let anchorApp = insertResult.targetApp ?? dictationTargetApp
                    if let span = insertResult.span,
                       span.location != NSNotFound,
                       let app = anchorApp,
                       let bundleID = app.bundleIdentifier {
                        CorrectionWatcher.shared.arm(anchor: InsertionAnchor(
                            bundleID: bundleID,
                            pid: app.processIdentifier,
                            inserted: insertResult.inserted,
                            span: span,
                            valueLengthAtInsert: nil,  // arm() reads the real field value length
                            at: Date()
                        ))
                    }
                }
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
        // Pre-recording only warmed the engine (ring-buffer mode); nothing was
        // captured yet. The engine stays warm — cooldown reclaims it if unused.
        if isPreRecording {
            isPreRecording = false
            // Schedule cooldown so a chord that never became a hold still
            // releases the mic after the idle window.
            recorder.endCapture()
        }
        guard state.isRecording else { return }
        _ = recorder.endCapture()
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

    // MARK: - v1.1 "Fix that" correction (Signal C)

    /// Arms correction mode: the NEXT dictation is treated as the corrected
    /// version of the last one. Guarded so a stray tap with no recent dictation
    /// (or while busy) is a no-op, and auto-disarms after ~10s.
    func armCorrection() {
        guard let at = state.lastDictationAt, Date().timeIntervalSince(at) < 60,
              state.lastInsertedText != nil,
              !state.isRecording, !state.isTranscribing else {
            NSLog("[Haynoi] armCorrection: no recent dictation or busy — ignored")
            return
        }
        state.isCorrectionArmed = true
        NSLog("[Haynoi] Correction armed — next dictation corrects the last one")
        FloatingBarController.shared.showCorrectionHint()
        if UserDefaults.standard.bool(forKey: "soundEnabled") {
            SoundFeedback.shared.playStartTone()
        }
        // Auto-disarm if no dictation follows.
        correctionDisarmTimer?.invalidate()
        correctionDisarmTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state.isCorrectionArmed {
                    self.state.isCorrectionArmed = false
                    NSLog("[Haynoi] Correction auto-disarmed (no dictation within 10s)")
                }
            }
        }
    }

    /// Handles a correction dictation: replace the last inserted text in place,
    /// learn the diff (toast), and self-heal a fired rule the user reversed.
    private func handleCorrection(correctedTranscript: String) async {
        // 1. Snapshot the last-dictation basis.
        let t1 = state.lastTranscript
        let oldInserted = state.lastInsertedText
        let targetApp = state.lastTargetApp
        let span = state.lastInsertionSpan
        let firedIDs = state.lastFiredRuleIDs

        guard let oldInserted else {
            NSLog("[Haynoi] handleCorrection: no last-inserted text — inserting at cursor")
            _ = await TextInserter.insert(correctedTranscript, targetApp: targetApp)
            return
        }

        // 2. In-place replace of the old inserted span with the corrected text.
        let replacedInPlace = await TextInserter.replaceSpan(
            span, with: correctedTranscript, oldText: oldInserted, targetApp: targetApp)
        if !replacedInPlace {
            state.setTransientStatus("Sửa ở vị trí con trỏ — văn bản cũ vẫn còn")
        }

        // 3. Diff → wrong→right, then either self-heal a reversed fired rule or
        //    propose learning the new correction. Diff against the raw T1.
        let basis = t1 ?? oldInserted
        if let change = CorrectionDiff.extractChange(from: basis, to: correctedTranscript) {
            // 4. Self-heal: did the user correct BACK against a rule that just
            //    fired on T1? A fired rule changed wrong→right; the user typing
            //    `right`→`wrong` now means that rule was wrong here. Disable it —
            //    do NOT also learn the reverse (avoids oscillation §7.3).
            let firedRules = PersonalDictionary.shared.entries(withIDs: firedIDs)
            let reversed = firedRules.first { rule in
                guard let w = rule.wrong else { return false }
                return w.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(
                            change.right.precomposedStringWithCanonicalMapping) == .orderedSame &&
                       rule.right.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(
                            change.wrong.precomposedStringWithCanonicalMapping) == .orderedSame
            }
            if let reversed, let w = reversed.wrong {
                _ = PersonalDictionary.shared.disableMatchingReplacement(wrong: w, right: reversed.right)
                NSLog("[Haynoi] Self-heal: disabled reversed rule %@ → %@", w, reversed.right)
            } else {
                // Propose learning — suppress the toast in live contexts (§5.1).
                if !LiveContext.isActive() {
                    let wrong = change.wrong
                    let right = change.right
                    FloatingBarController.shared.showLearnToast(
                        wrong: wrong, right: right,
                        onRemember: {
                            // Explicit user action = trusted → confirmations = 2
                            // clears the >=2 activation gate immediately (§1.2).
                            _ = PersonalDictionary.shared.upsertLearnedReplacement(
                                wrong: wrong, right: right, confirmations: 2)
                            NSLog("[Haynoi] Learned (fix-that): %@ → %@", wrong, right)
                            // Metadata only: just which detector fired — never the term strings.
                            Analytics.capture("dictionary_term_learned", ["signal": "fixthat"])
                        },
                        onIgnore: {}
                    )
                }
            }
        }

        // 5. Update last-dictation state to the corrected values so a second
        //    fix-that corrects the correction. Update the most recent history
        //    entry in place rather than adding a new row.
        let newSpan: NSRange? = {
            guard let span, span.location != NSNotFound, replacedInPlace else { return nil }
            return NSRange(location: span.location, length: correctedTranscript.utf16.count)
        }()
        state.lastTranscript = correctedTranscript
        state.lastInsertedText = correctedTranscript
        state.lastInsertionSpan = newSpan
        state.lastDictationAt = Date()
        state.lastFiredRuleIDs = []
        state.updateLastTranscription(correctedTranscript)

        // v1.3 — re-arm Signal A with the corrected values so an edit-in-place
        // AFTER a fix-that is also captured. Only when the in-place replace landed
        // a known span in an AX-cooperative app (CorrectionWatcher gates the rest).
        if let newSpan, newSpan.location != NSNotFound,
           let app = targetApp, let bundleID = app.bundleIdentifier {
            CorrectionWatcher.shared.arm(anchor: InsertionAnchor(
                bundleID: bundleID,
                pid: app.processIdentifier,
                inserted: correctedTranscript,
                span: newSpan,
                valueLengthAtInsert: nil,  // arm() reads the real field value length
                at: Date()
            ))
        }

        if UserDefaults.standard.bool(forKey: "soundEnabled"),
           UserDefaults.standard.bool(forKey: "successDinkEnabled") {
            SoundFeedback.shared.playSuccessTone()
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
