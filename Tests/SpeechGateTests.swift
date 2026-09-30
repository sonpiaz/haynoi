import XCTest
@testable import Haynoi

/// W37-1389: quiet speech with pauses was dropped as "No speech detected"
/// because the gate compared the whole-buffer average with 0.005.
final class SpeechGateTests: XCTestCase {

    private let rate = 16000

    /// Deterministic noise, so a failure reproduces.
    private func noise(seconds: Double, rms: Float, seed: UInt64 = 1) -> [Float] {
        var state = seed
        let scale = rms * Float(3).squareRoot()  // uniform in [-a, a] has rms a/√3
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * scale
        }
    }

    /// A voice-like burst added onto `buffer` from `at` for `seconds`.
    private func addVoice(_ buffer: inout [Float], at: Double, seconds: Double, amplitude: Float) {
        let start = Int(at * Double(rate))
        for i in 0..<Int(seconds * Double(rate)) where start + i < buffer.count {
            let t = Float(i) / Float(rate)
            buffer[start + i] += amplitude * sin(2 * .pi * 180 * t) * (0.85 + 0.15 * sin(2 * .pi * 4 * t))
        }
    }

    private func average(_ s: [Float]) -> Float {
        (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    }

    func testQuietVoiceWithPausesIsSpeech() {
        // 30 s hold, two seconds of quiet voice in total, a quiet room.
        var buffer = noise(seconds: 30, rms: 0.0015)
        addVoice(&buffer, at: 3, seconds: 1.2, amplitude: 0.012)
        addVoice(&buffer, at: 18, seconds: 0.8, amplitude: 0.012)
        XCTAssertLessThan(average(buffer), 0.005, "the old gate would have dropped this")
        XCTAssertTrue(PipelineController.hasSpeech(buffer))
    }

    func testNormalVoiceStillPasses() {
        var buffer = noise(seconds: 5, rms: 0.002)
        addVoice(&buffer, at: 0.5, seconds: 4, amplitude: 0.05)
        XCTAssertTrue(PipelineController.hasSpeech(buffer))
    }

    func testQuietRoomIsNotSpeech() {
        XCTAssertFalse(PipelineController.hasSpeech(noise(seconds: 30, rms: 0.0015)))
    }

    func testSteadyFanIsNotSpeech() {
        let fan = noise(seconds: 20, rms: 0.004, seed: 7)
        XCTAssertLessThan(average(fan), 0.005)
        XCTAssertFalse(PipelineController.hasSpeech(fan))
    }

    func testStartToneAloneIsNotSpeech() {
        // The mic can hear the 0.42 s start tone; a silent hold must still fail.
        var buffer = noise(seconds: 30, rms: 0.0015)
        addVoice(&buffer, at: 0.3, seconds: 0.42, amplitude: 0.05)
        XCTAssertLessThan(average(buffer), 0.005)
        XCTAssertFalse(PipelineController.hasSpeech(buffer))
    }

    func testScatteredClicksAreNotSpeech() {
        // Start tone plus short clicks: enough frames in total, none of them a syllable.
        var buffer = noise(seconds: 30, rms: 0.0015)
        addVoice(&buffer, at: 0.3, seconds: 0.42, amplitude: 0.05)
        for k in 0..<10 { addVoice(&buffer, at: 5 + Double(k) * 2, seconds: 0.09, amplitude: 0.02) }
        XCTAssertLessThan(average(buffer), 0.005)
        XCTAssertFalse(PipelineController.hasSpeech(buffer))
    }

    func testEmptyAndTinyBuffersAreNotSpeech() {
        XCTAssertFalse(PipelineController.hasSpeech([]))
        XCTAssertFalse(PipelineController.hasSpeech([Float](repeating: 0.5, count: 100)))
    }
}
