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

    private init() {}

    // MARK: - Public

    func startRecording() throws {
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

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] pcm, _ in
            self?.processTapBuffer(pcm, converter: converter, targetFormat: whisperFormat)
        }

        eng.prepare()
        try eng.start()
        NSLog("[Haynoi] Recording started")
    }

    /// Stops recording and returns the accumulated 16kHz mono samples.
    func stopRecording() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        lock.lock()
        let samples = buffer
        buffer.removeAll()
        lock.unlock()

        DispatchQueue.main.async { [weak self] in self?.audioLevel = 0 }
        NSLog("[Haynoi] Recording stopped, %d samples (%.1fs)", samples.count, Float(samples.count) / 16000)
        return samples
    }

    // MARK: - Private

    private func processTapBuffer(_ pcm: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let ratio = 16000.0 / pcm.format.sampleRate
        let frameCount = AVAudioFrameCount(Double(pcm.frameLength) * ratio)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return pcm
        }
        guard error == nil, let data = converted.floatChannelData?[0] else { return }

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
