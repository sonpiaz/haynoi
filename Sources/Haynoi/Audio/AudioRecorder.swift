import AVFoundation
import Foundation

/// Records audio from the mic into a Float32 buffer at 16kHz mono (for Whisper).
///
/// Warm-engine design (Wispr Flow keep-warm pattern):
/// The AVAudioEngine is built and started ONCE (off the main actor) and kept
/// running between dictations. While warm but NOT capturing, the tap appends
/// converted 16kHz samples into a rolling ring buffer (~2.0s, drop-oldest) so a
/// `beginCapture(preRollMs:)` can splice the last N ms of already-captured audio
/// into the recording — the user's first words are never clipped, even on a cold
/// Bluetooth mic. After 60s of inactivity the engine is stopped entirely to
/// release the mic + orange-dot indicator.
///
/// Thread-safety: the tap callback runs on the audio thread; `ensureWarm`,
/// `beginCapture`, `endCapture` may be called from the main actor. All shared
/// mutable state (ring buffer, recording buffer, capture flag, format handles)
/// is guarded by `lock`. The tap callback stays allocation-light under the lock.
/// CRITICAL macOS rule from this codebase: `engine.start()` must NOT run on the
/// main thread; any TIS/TSM call must be on the main thread (none here).
final class AudioRecorder {
    static let shared = AudioRecorder()

    private var engine: AVAudioEngine?

    /// Recording buffer — samples accumulated while `isCapturing` is true.
    private var buffer: [Float] = []

    /// Rolling pre-roll ring buffer — last ~2.0s of 16kHz samples, kept while
    /// warm but not capturing so `beginCapture` can splice in pre-roll.
    private var ringBuffer: [Float] = []
    private static let ringCapacitySamples = 32_000  // 2.0s @ 16kHz

    /// True between `beginCapture` and `endCapture`.
    private var isCapturing = false

    /// Guards engine lifecycle, buffers, capture flag, and the live converter/format.
    private let lock = NSLock()

    /// One-shot callback fired (on the main thread) when the FIRST live tap
    /// buffer arrives after `beginCapture`. Used to play the start tone at the
    /// honest moment capture goes live. Cleared after firing.
    private var captureLiveCallback: (() -> Void)?

    /// Whether the engine is warm (built + started). Read on the main actor.
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return engine != nil
    }

    /// Current RMS audio level (0…1), updated from the tap callback.
    @Published var audioLevel: Float = 0

    // Track when the most recent tap callback fired so the watchdog can detect a
    // silent-death (AirPods disconnect, etc.) while capturing. Written from the
    // audio tap thread, engineQueue, caller threads and NotificationCenter; read
    // from the main-thread watchdog. ALL access MUST go through the helpers below
    // so it stays guarded by `lock` (a torn read of the 128-bit Date struct on
    // ARM64 would corrupt the watchdog heartbeat). Never touch `_lastTapFireTime`
    // directly outside these accessors.
    private var _lastTapFireTime: Date?
    private func setLastTapFireTime(_ value: Date?) {
        lock.lock(); _lastTapFireTime = value; lock.unlock()
    }
    private func getLastTapFireTime() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastTapFireTime
    }

    // Observes AVAudioEngineConfigurationChange to handle device hot-swap.
    private var engineConfigObserver: NSObjectProtocol?

    // Watchdog timer — fires every 500ms while CAPTURING is active.
    private var watchdogTimer: Timer?

    // Cooldown timer — stops the warm engine 60s after the last endCapture.
    private var cooldownTimer: Timer?
    private static let cooldownInterval: TimeInterval = 60

    // Dedicated serial queue for engine start/stop so it never blocks the main
    // actor (slow Bluetooth A2DP→HFP switches can take 1–3s).
    private let engineQueue = DispatchQueue(label: "com.haynoi.audio.engine")

    // Live format handles for the current warm engine (guarded by `lock`).
    private var whisperFormat: AVAudioFormat?

    private init() {}

    // MARK: - Warm-up

    /// Builds the engine + converter + tap ONCE and starts it OFF the main actor.
    /// Idempotent: if already warm, only cancels any pending cooldown. Safe to
    /// call on a chord (modifier-down) — cooldown reclaims the mic if unused.
    func ensureWarm() {
        cancelCooldown()

        lock.lock()
        let alreadyWarm = engine != nil
        lock.unlock()
        if alreadyWarm { return }

        // Build + start off the main actor; hop back only for @Published state.
        engineQueue.async { [weak self] in
            self?.buildAndStartEngine()
        }
    }

    /// Builds the engine and starts it. Runs on `engineQueue` (never main).
    private func buildAndStartEngine() {
        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            NSLog("[Haynoi] ensureWarm: bad hw format, aborting warm-up")
            return
        }
        NSLog("[Haynoi] Mic format: %.0fHz, %dch", hwFormat.sampleRate, hwFormat.channelCount)

        guard let whisper = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            NSLog("[Haynoi] ensureWarm: could not create whisper format")
            return
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: whisper) else {
            NSLog("[Haynoi] ensureWarm: could not create converter")
            return
        }

        lock.lock()
        // Re-check we weren't warmed concurrently by another call.
        guard engine == nil else { lock.unlock(); return }
        engine = eng
        whisperFormat = whisper
        ringBuffer.removeAll(keepingCapacity: true)
        // Preserve an in-flight capture: on a cold start beginCapture() can run
        // before this block finishes (slow Bluetooth HAL). Resetting isCapturing
        // here would silently kill that dictation.
        if !isCapturing {
            buffer.removeAll(keepingCapacity: true)
        }
        lock.unlock()

        setLastTapFireTime(Date())
        installTap(on: inputNode, converter: converter, hwFormat: hwFormat, whisperFormat: whisper)

        eng.prepare()
        do {
            try eng.start()
        } catch {
            NSLog("[Haynoi] ensureWarm: engine.start() failed: %@", error.localizedDescription)
            inputNode.removeTap(onBus: 0)
            lock.lock()
            engine = nil
            whisperFormat = nil
            lock.unlock()
            return
        }

        // Observe device configuration changes (e.g. AirPods disconnect).
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: eng,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange(engine: eng, whisperFormat: whisper)
        }

        NSLog("[Haynoi] Engine warm (running, ring-buffer mode)")
    }

    // MARK: - Capture Gate

    /// Atomically splices the last `preRollMs` of ring buffer into the recording
    /// buffer, then switches the tap to record mode. Ensures the engine is warm
    /// first (warming is async, so the first samples may arrive shortly after).
    /// The one-shot `captureLive` callback fires when the first live buffer lands.
    func beginCapture(preRollMs: Int) {
        cancelCooldown()
        ensureWarm()  // no-op if already warm

        lock.lock()
        // Splice pre-roll: take the last preRollMs of ring buffer.
        let preRollSamples = max(0, min(ringBuffer.count, (preRollMs * 16000) / 1000))
        if preRollSamples > 0 {
            buffer = Array(ringBuffer.suffix(preRollSamples))
        } else {
            buffer.removeAll(keepingCapacity: true)
        }
        isCapturing = true
        lock.unlock()

        setLastTapFireTime(Date())
        startWatchdog()
        NSLog("[Haynoi] Capture begun (pre-roll %d samples = %.0fms)",
              preRollSamples, Double(preRollSamples) / 16.0)
    }

    /// Registers the one-shot callback fired on the main thread when the first
    /// live tap buffer arrives after `beginCapture`. If the engine is already
    /// warm and capturing, this typically fires within ~1 audio frame.
    func onCaptureLive(_ callback: @escaping () -> Void) {
        lock.lock()
        captureLiveCallback = callback
        lock.unlock()
    }

    /// Stops accumulating, returns the recorded 16kHz mono samples, and returns
    /// the engine to ring-buffer mode (engine stays running). Schedules cooldown.
    @discardableResult
    func endCapture() -> [Float] {
        stopWatchdog()

        lock.lock()
        let wasCapturing = isCapturing
        isCapturing = false
        // When we were NOT actually capturing (launch warm-up at setup(), or a
        // pre-recording chord that never became a hold), leave the warm engine's
        // ring buffer untouched — it just started filling and clearing it here is
        // wasteful. Only harvest + reset the recording buffer on a real capture.
        let samples: [Float]
        if wasCapturing {
            samples = buffer
            buffer.removeAll(keepingCapacity: true)
            ringBuffer.removeAll(keepingCapacity: true)
        } else {
            samples = []
        }
        // Always drop a pending captureLive callback — a chord that never became
        // a hold must not leave a stale tone trigger for the next dictation.
        captureLiveCallback = nil
        lock.unlock()

        // Always schedule cooldown so a warm-but-idle engine is still reclaimed.
        scheduleCooldown()

        if wasCapturing {
            DispatchQueue.main.async { [weak self] in self?.audioLevel = 0 }
            NSLog("[Haynoi] Capture ended, %d samples (%.1fs); engine stays warm",
                  samples.count, Float(samples.count) / 16000)
        } else {
            NSLog("[Haynoi] endCapture (no active capture); cooldown scheduled")
        }
        return samples
    }

    // MARK: - Legacy compatibility shims

    /// Back-compat: warm + begin capture with no pre-roll. Retained so any
    /// stray call site still records. New code should use ensureWarm/beginCapture.
    func startRecording() throws {
        beginCapture(preRollMs: 0)
    }

    /// Back-compat alias for endCapture().
    @discardableResult
    func stopRecording() -> [Float] {
        return endCapture()
    }

    // MARK: - Cooldown

    /// Stops the warm engine `cooldownInterval` seconds after the last capture,
    /// releasing the mic + orange-dot indicator. Cancelled on next use.
    private func scheduleCooldown() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cooldownTimer?.invalidate()
            self.cooldownTimer = Timer.scheduledTimer(
                withTimeInterval: AudioRecorder.cooldownInterval, repeats: false
            ) { [weak self] _ in
                self?.shutdownEngine()
            }
        }
    }

    private func cancelCooldown() {
        // Fix #3: cancel SYNCHRONOUSLY. ensureWarm()/beginCapture() call this and
        // then immediately check engine state + dispatch buildAndStartEngine. If
        // the cancel were async, the cooldown timer could fire AFTER the freshly
        // built engine is in place and tear it down (build → shutdown → engine
        // gone, since shutdownEngine serializes on engineQueue after the build).
        // Timer.invalidate() must run on the RunLoop the timer was scheduled on
        // (the main RunLoop), so hop to main synchronously when off-main.
        let cancel = { [weak self] in
            self?.cooldownTimer?.invalidate()
            self?.cooldownTimer = nil
        }
        if Thread.isMainThread {
            cancel()
        } else {
            DispatchQueue.main.sync(execute: cancel)
        }
    }

    /// Fully stops + releases the engine (off the main actor). Called by the
    /// cooldown timer and on hard abort.
    private func shutdownEngine() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            // Fix #2: remove the config-change observer on engineQueue (the same
            // queue that set it in buildAndStartEngine) so the write/read of
            // `engineConfigObserver` is serialized on one thread.
            if let obs = self.engineConfigObserver {
                NotificationCenter.default.removeObserver(obs)
                self.engineConfigObserver = nil
            }
            self.lock.lock()
            let eng = self.engine
            self.engine = nil
            self.whisperFormat = nil
            self.isCapturing = false
            self.buffer.removeAll(keepingCapacity: false)
            self.ringBuffer.removeAll(keepingCapacity: false)
            self.lock.unlock()

            eng?.inputNode.removeTap(onBus: 0)
            eng?.stop()
            self.setLastTapFireTime(nil)
            NSLog("[Haynoi] Engine cooled down (stopped, mic released)")
        }
    }

    // MARK: - Tap Installation

    /// Installs the audio tap with the given converter. Extracted so it can be
    /// re-installed after an AVAudioEngineConfigurationChange.
    private func installTap(
        on inputNode: AVAudioInputNode,
        converter: AVAudioConverter,
        hwFormat: AVAudioFormat,
        whisperFormat: AVAudioFormat
    ) {
        // 1024 frames ≈ 21ms at 48kHz — the captureLive callback (start tone)
        // fires within one buffer, so the go-cue lands right on the keypress.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] pcm, _ in
            self?.processTapBuffer(pcm, converter: converter, targetFormat: whisperFormat)
        }
    }

    // MARK: - Device Configuration Change

    /// Called when AVAudioEngine signals a hardware config change (e.g. AirPods
    /// disconnect). Rebuilds the tap with the new input node format. Preserves
    /// the recording + ring buffers. Aborts (capturing only) if rebuild fails.
    private func handleEngineConfigurationChange(
        engine eng: AVAudioEngine,
        whisperFormat whisper: AVAudioFormat
    ) {
        lock.lock()
        let isCurrent = (engine === eng)
        let capturing = isCapturing
        lock.unlock()
        guard isCurrent else { return }
        NSLog("[Haynoi] AVAudioEngineConfigurationChange received — rebuilding tap")

        let inputNode = eng.inputNode
        inputNode.removeTap(onBus: 0)

        // Restart the engine so the new hardware format is picked up.
        do {
            try eng.start()
        } catch {
            NSLog("[Haynoi] Engine restart after config change failed: %@", error.localizedDescription)
            if capturing { abortRecordingWithError("Microphone disconnected") }
            else { shutdownEngine() }
            return
        }

        let newHWFormat = inputNode.outputFormat(forBus: 0)
        guard newHWFormat.sampleRate > 0, newHWFormat.channelCount > 0 else {
            NSLog("[Haynoi] New hw format invalid after config change")
            if capturing { abortRecordingWithError("Microphone disconnected") }
            else { shutdownEngine() }
            return
        }

        guard let newConverter = AVAudioConverter(from: newHWFormat, to: whisper) else {
            NSLog("[Haynoi] Could not create converter for new hw format")
            if capturing { abortRecordingWithError("Microphone disconnected") }
            else { shutdownEngine() }
            return
        }

        installTap(on: inputNode, converter: newConverter, hwFormat: newHWFormat, whisperFormat: whisper)
        setLastTapFireTime(Date())
        NSLog("[Haynoi] Tap rebuilt after device change: %.0fHz %dch",
              newHWFormat.sampleRate, newHWFormat.channelCount)
    }

    // MARK: - Watchdog

    /// Starts a repeating 500ms timer that checks whether the tap is still firing
    /// while CAPTURING. If no callback has fired for >1s we treat it as a silent
    /// device failure and abort the capture.
    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchdogTimer?.invalidate()
            self.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkWatchdog()
            }
        }
    }

    private func stopWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.watchdogTimer = nil
        }
    }

    private func checkWatchdog() {
        lock.lock()
        let warm = engine != nil
        let capturing = isCapturing
        lock.unlock()
        guard warm, capturing, let lastFire = getLastTapFireTime() else { return }
        let elapsed = Date().timeIntervalSince(lastFire)
        if elapsed > 1.0 {
            NSLog("[Haynoi] Watchdog: no tap callback for %.1fs — assuming device failure", elapsed)
            abortRecordingWithError("Microphone disconnected")
        }
    }

    // MARK: - Abort

    /// Stops the engine entirely and notifies PipelineController via a main-thread
    /// callback so it can surface the error and play the error tone. Used only
    /// when a device fails mid-capture.
    private func abortRecordingWithError(_ reason: String) {
        stopWatchdog()
        shutdownEngine()

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: AudioRecorder.didAbortRecording,
                object: nil,
                userInfo: ["reason": reason]
            )
        }
        NSLog("[Haynoi] Recording aborted: %@", reason)
    }

    /// Posted on the main thread when the engine self-aborts (device failure).
    /// PipelineController observes this notification.
    static let didAbortRecording = Notification.Name("HaynoiAudioRecorderDidAbortRecording")

    // MARK: - Tap Processing

    private func processTapBuffer(_ pcm: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        setLastTapFireTime(Date())

        // Round frame count UP (+2 frames headroom) to avoid truncation.
        let ratio = 16000.0 / pcm.format.sampleRate
        let frameCount = AVAudioFrameCount(ceil(Double(pcm.frameLength) * ratio) + 2)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        // Canonical consumed-flag pattern — prevents sample duplication when the
        // converter calls the input block twice per convert cycle.
        var consumed = false
        var convertError: NSError?
        converter.convert(to: converted, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard convertError == nil, let data = converted.floatChannelData?[0] else { return }

        let count = Int(converted.frameLength)
        let samples = Array(UnsafeBufferPointer(start: data, count: count))

        // Append to either the recording buffer (capturing) or the ring buffer
        // (warm, idle). Fire the one-shot captureLive callback on the first live
        // buffer after beginCapture. Keep work under the lock allocation-light.
        var fireCaptureLive: (() -> Void)?
        lock.lock()
        if isCapturing {
            buffer.append(contentsOf: samples)
            if let cb = captureLiveCallback {
                fireCaptureLive = cb
                captureLiveCallback = nil
            }
        } else {
            ringBuffer.append(contentsOf: samples)
            let overflow = ringBuffer.count - AudioRecorder.ringCapacitySamples
            if overflow > 0 {
                ringBuffer.removeFirst(overflow)
            }
        }
        lock.unlock()

        if let fire = fireCaptureLive {
            DispatchQueue.main.async { fire() }
        }

        // RMS for level meter
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / max(Float(count), 1))
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = min(1.0, rms * 10)
        }
    }
}

enum RecorderError: LocalizedError {
    case badFormat
    case converterFailed

    var errorDescription: String? {
        switch self {
        case .badFormat: return "Invalid audio format"
        case .converterFailed: return "Could not create audio converter"
        }
    }
}
