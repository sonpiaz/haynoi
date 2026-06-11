import AVFoundation
import Foundation

/// Persists failed-transcription WAV files to
/// ~/Library/Application Support/Haynoi/failed/
///
/// Keeps at most `maxSaved` entries (newest N, oldest pruned).
/// Exposed as a simple save/load/prune surface used by PipelineController.
enum FailedDictationStore {

    private static let maxSaved = 5

    static var failedDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Haynoi/failed", isDirectory: true)
    }

    // MARK: - Save

    /// Encodes `samples` to WAV and writes to the failed/ directory.
    /// Prunes old files so at most `maxSaved` remain.
    /// Returns the saved URL on success, nil on failure.
    static func save(samples: [Float], sampleRate: Int = 16000) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: failedDirectory, withIntermediateDirectories: true
            )
        } catch {
            NSLog("[Haynoi] FailedDictationStore: can't create directory: %@",
                  error.localizedDescription)
            return nil
        }

        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let dest = failedDirectory.appendingPathComponent("dictation_\(ts).wav")

        guard let wavData = try? createWAV(samples: samples, sampleRate: sampleRate) else {
            NSLog("[Haynoi] FailedDictationStore: WAV encode failed")
            return nil
        }

        do {
            try wavData.write(to: dest, options: .atomic)
            NSLog("[Haynoi] FailedDictationStore: saved %@", dest.lastPathComponent)
            pruneOldFiles()
            return dest
        } catch {
            NSLog("[Haynoi] FailedDictationStore: write error: %@",
                  error.localizedDescription)
            return nil
        }
    }

    // MARK: - Load newest

    /// Returns the samples from the most recently saved failed dictation,
    /// or nil if none exist.
    static func loadNewest() -> [Float]? {
        guard let newest = newestFileURL() else { return nil }
        return decodeSamples(from: newest)
    }

    /// URL of the newest saved WAV, or nil.
    static func newestFileURL() -> URL? {
        savedFiles().last
    }

    /// True if at least one saved file exists.
    static var hasAny: Bool { newestFileURL() != nil }

    /// Deletes the newest saved WAV file. Call after a successful retry so the
    /// Retry button no longer appears and a second retry cannot re-insert the
    /// same text.
    static func deleteNewest() {
        guard let url = newestFileURL() else { return }
        do {
            try FileManager.default.removeItem(at: url)
            NSLog("[Haynoi] FailedDictationStore: deleted %@", url.lastPathComponent)
        } catch {
            NSLog("[Haynoi] FailedDictationStore: delete error: %@",
                  error.localizedDescription)
        }
    }

    // MARK: - Prune

    private static func pruneOldFiles() {
        let files = savedFiles()
        guard files.count > maxSaved else { return }
        let toDelete = files.dropLast(maxSaved)
        for url in toDelete {
            try? FileManager.default.removeItem(at: url)
            NSLog("[Haynoi] FailedDictationStore: pruned %@", url.lastPathComponent)
        }
    }

    // MARK: - Helpers

    /// Returns saved WAV files sorted oldest→newest.
    private static func savedFiles() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: failedDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return items
            .filter { $0.pathExtension == "wav" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return d0 < d1
            }
    }

    /// Decodes a WAV file into raw Float samples at 16 kHz mono.
    private static func decodeSamples(from url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else {
            NSLog("[Haynoi] FailedDictationStore: can't open %@", url.lastPathComponent)
            return nil
        }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            NSLog("[Haynoi] FailedDictationStore: read error: %@", error.localizedDescription)
            return nil
        }
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }

    // MARK: - WAV Encoder (mirrors STTProvider.createWAV)

    private static func createWAV(samples: [Float], sampleRate: Int) throws -> Data {
        let float32Format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: float32Format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count { channelData[i] = samples[i] }

        let int16Settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("haynoi_failed_\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: tmpURL, settings: int16Settings)
        try file.write(from: buffer)
        let data = try Data(contentsOf: tmpURL)
        try? FileManager.default.removeItem(at: tmpURL)
        return data
    }
}
