import AVFoundation
import Foundation

/// Records audio from the mic into a Float32 buffer at 16kHz mono (for Whisper).
/// Thread-safe: tap callback writes on audio thread, stopRecording reads on main.
final class AudioRecorder {
    static let shared = AudioRecorder()

    private var engine: AVAudioEngine?
    private var buffer: [Float] = []
    private let lock = NSLock()

    var isRunning: Bool { engine != nil }

    /// Current RMS audio level (0…1), updated from the tap callback.
    @Published var audioLevel: Float = 0

    // Fix #5: track when the most recent tap callback fired so the watchdog
    // can detect a silent-death (AirPods disconnect, etc.).
    private var lastTapFireTime: Date?

    // Fix #5: observes AVAudioEngineConfigurationChange to handle device hot-swap.
    private var engineConfigObserver: NSObjectProtocol?

    // Fix #5: watchdog timer — fires every 500ms while recording is active.
    private var watchdogTimer: Timer?

    private init() {}

    // MARK: - Public

    func startRecording() throws {
        // Fix #7: defensive guard — if a stale engine is running, stop it first.
        if engine != nil {
            _ = stopRecording()
        }

        let eng = AVAudioEngine()
        self.engine = eng                       // assign FIRST

        let inputNode = eng.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            self.engine = nil
            throw RecorderError.badFormat
        }
        NSLog("[Haynoi] Mic format: %.0fHz, %dch", hwFormat.sampleRate, hwFormat.channelCount)

        guard let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            self.engine = nil
            throw RecorderError.badFormat
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: whisperFormat) else {
            self.engine = nil
            throw RecorderError.converterFailed
        }

        lock.lock()
        buffer.removeAll()
        lock.unlock()

        lastTapFireTime = Date()
        installTap(on: inputNode, converter: converter, hwFormat: hwFormat, whisperFormat: whisperFormat)

        eng.prepare()
        try eng.start()

        // Fix #5: observe device configuration changes (e.g. AirPods disconnect).
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: eng,
            queue: nil
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange(
                engine: eng,
                whisperFormat: whisperFormat
            )
        }

        // Fix #5: watchdog — detect silent death when tap stops firing.
        startWatchdog()

        NSLog("[Haynoi] Recording started")
    }

    /// Stops recording and returns the accumulated 16kHz mono samples.
    @discardableResult
    func stopRecording() -> [Float] {
        stopWatchdog()

        // Fix #5: remove config-change observer.
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lastTapFireTime = nil

        lock.lock()
        let samples = buffer
        buffer.removeAll()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in self?.audioLevel = 0 }
        NSLog("[Haynoi] Recording stopped, %d samples (%.1fs)", samples.count, Float(samples.count) / 16000)
        return samples
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
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] pcm, _ in
            self?.processTapBuffer(pcm, converter: converter, targetFormat: whisperFormat)
        }
    }

    // MARK: - Device Configuration Change (Fix #5)

    /// Called when AVAudioEngine signals a hardware config change (e.g. AirPods
    /// disconnect). Attempts to rebuild the tap with the new input node format,
    /// preserving the samples buffered so far. Aborts with an error if rebuild fails.
    private func handleEngineConfigurationChange(
        engine eng: AVAudioEngine,
        whisperFormat: AVAudioFormat
    ) {
        guard engine === eng else { return }
        NSLog("[Haynoi] AVAudioEngineConfigurationChange received — rebuilding tap")

        let inputNode = eng.inputNode
        inputNode.removeTap(onBus: 0)

        // Restart the engine so the new hardware format is picked up.
        do {
            try eng.start()
        } catch {
            NSLog("[Haynoi] Engine restart after config change failed: %@", error.localizedDescription)
            abortRecordingWithError("Microphone disconnected")
            return
        }

        let newHWFormat = inputNode.outputFormat(forBus: 0)
        guard newHWFormat.sampleRate > 0, newHWFormat.channelCount > 0 else {
            NSLog("[Haynoi] New hw format invalid after config change")
            abortRecordingWithError("Microphone disconnected")
            return
        }

        guard let newConverter = AVAudioConverter(from: newHWFormat, to: whisperFormat) else {
            NSLog("[Haynoi] Could not create converter for new hw format")
            abortRecordingWithError("Microphone disconnected")
            return
        }

        installTap(on: inputNode, converter: newConverter, hwFormat: newHWFormat, whisperFormat: whisperFormat)
        lastTapFireTime = Date()
        NSLog("[Haynoi] Tap rebuilt after device change: %.0fHz %dch",
              newHWFormat.sampleRate, newHWFormat.channelCount)
    }

    // MARK: - Watchdog (Fix #5)

    /// Starts a repeating 500ms timer that checks whether the tap is still firing.
    /// If no callback has fired for >1s while the engine is set, we treat it as a
    /// silent device failure and abort.
    private func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkWatchdog()
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func checkWatchdog() {
        guard engine != nil, let lastFire = lastTapFireTime else { return }
        let elapsed = Date().timeIntervalSince(lastFire)
        if elapsed > 1.0 {
            NSLog("[Haynoi] Watchdog: no tap callback for %.1fs — assuming device failure", elapsed)
            abortRecordingWithError("Microphone disconnected")
        }
    }

    // MARK: - Abort

    /// Stops the engine, drains remaining samples, then notifies PipelineController
    /// via a main-thread callback so it can surface the error and play the error tone.
    private func abortRecordingWithError(_ reason: String) {
        stopWatchdog()
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        lastTapFireTime = nil

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

    // MARK: - Private

    private func processTapBuffer(_ pcm: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        lastTapFireTime = Date()

        // Fix #6: round frame count UP (+2 frames headroom) to avoid truncation.
        let ratio = 16000.0 / pcm.format.sampleRate
        let frameCount = AVAudioFrameCount(ceil(Double(pcm.frameLength) * ratio) + 2)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        // Fix #6: canonical consumed-flag pattern — prevents sample duplication
        // when the converter calls the input block twice per convert cycle.
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

        lock.lock()
        buffer.append(contentsOf: samples)
        lock.unlock()

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
