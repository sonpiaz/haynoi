import Speech
import XCTest
@testable import Haynoi

/// Automatic never-die gate: Vietnamese TTS audio, forced primary STT failure,
/// on-device fallback returns a transcript inside the 2.5s release budget.
/// Does not need a live microphone or a human voice.
final class NeverDieTTSFallbackTests: XCTestCase {

    private struct Sample {
        let id: String
        let spoken: String
    }

    private static let samples: [Sample] = [
        Sample(id: "chao", spoken: "xin chào đây là bản thử"),
        Sample(id: "neverdie", spoken: "hay nội không bao giờ chết"),
        Sample(id: "control", spoken: "giữ phím control để nói"),
    ]

    private static let fixtureDir: URL = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("haynoi/.internal/manager/tts-fixtures")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func testVietnameseTTSFallbackBeatsCloudDeadline() async throws {
        XCTAssertEqual(PipelineController.cloudDeadline, 2.5, accuracy: 0.001)
        try Self.generateFixtures()
        try await Self.ensureSpeechAuthorized()

        var lines: [String] = ["never-die TTS fallback"]
        for sample in Self.samples {
            let url = Self.fixtureURL(sample.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), sample.id)

            let onDevice = try await Self.transcribeVietnamese(url)
            XCTAssertFalse(
                onDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Apple Speech returned empty text for \(sample.id)"
            )

            // Release-path budget: cloud already failed; choosing on-device text
            // must be well under 2.5s (the text was ready during hold).
            let started = Date()
            let resolved = PipelineController.resolveTranscript(
                cloud: .failure(STTError.serverError("forced upstream failure (test)")),
                deadlineExceeded: false,
                onDevice: onDevice
            )
            let elapsed = Date().timeIntervalSince(started)

            XCTAssertEqual(resolved?.source, .onDevice, sample.id)
            XCTAssertEqual(resolved?.text, onDevice.trimmingCharacters(in: .whitespacesAndNewlines), sample.id)
            XCTAssertLessThan(
                elapsed,
                PipelineController.cloudDeadline,
                "fallback for \(sample.id) took \(elapsed)s"
            )
            lines.append(
                "\(sample.id): spoken=\(sample.spoken) on-device=\(onDevice) resolve=\(String(format: "%.4f", elapsed))s"
            )
        }

        let report = Self.fixtureDir.appendingPathComponent("RESULT.txt")
        try lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
    }

    func testForcedOutOfCreditsAndNoConnectionAlsoUseTTSTranscript() throws {
        try Self.generateFixtures()
        let onDevice = "xin chào đây là bản thử"
        for error in [STTError.outOfCredits, STTError.noConnection] as [Error] {
            let started = Date()
            let resolved = PipelineController.resolveTranscript(
                cloud: .failure(error),
                deadlineExceeded: false,
                onDevice: onDevice
            )
            XCTAssertEqual(resolved?.source, .onDevice)
            XCTAssertEqual(resolved?.text, onDevice)
            XCTAssertLessThan(Date().timeIntervalSince(started), PipelineController.cloudDeadline)
        }
    }

    // MARK: - Fixtures

    private static func fixtureURL(_ id: String) -> URL {
        fixtureDir.appendingPathComponent("\(id).aiff")
    }

    @discardableResult
    static func generateFixtures() throws -> [URL] {
        var urls: [URL] = []
        for sample in samples {
            let url = fixtureURL(sample.id)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            proc.arguments = ["-v", "Linh", "-o", url.path, sample.spoken]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw NSError(
                    domain: "haynoi.tts",
                    code: Int(proc.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "say failed for \(sample.id)"]
                )
            }
            urls.append(url)
        }
        return urls
    }

    private static func ensureSpeechAuthorized() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return
        case .denied, .restricted:
            throw XCTSkip("Speech recognition not authorized for the Debug host (status \(status.rawValue))")
        case .notDetermined:
            let granted: Bool = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    cont.resume(returning: newStatus == .authorized)
                }
            }
            if !granted {
                throw XCTSkip("Speech recognition prompt was not granted")
            }
        @unknown default:
            throw XCTSkip("Unknown speech auth status")
        }
    }

    private static func transcribeVietnamese(_ url: URL) async throws -> String {
        let locale = Locale(identifier: "vi-VN")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw XCTSkip("vi-VN SFSpeechRecognizer unavailable")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) {
            request.addsPunctuation = false
        }
        return try await withCheckedThrowingContinuation { cont in
            var settled = false
            recognizer.recognitionTask(with: request) { result, error in
                if settled { return }
                if let error {
                    settled = true
                    cont.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                settled = true
                cont.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }
}
