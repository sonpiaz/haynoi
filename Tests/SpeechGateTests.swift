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

    /// 29/09: "Nói ngắn ra thì nó không nghe". A one-word reply, said softly,
    /// with no start tone in the mic (headphones, sound off): 0.3.11 required
    /// 0.6 s of voice and dropped it.
    func testShortSoftReplyWithoutToneIsSpeech() {
        var buffer = noise(seconds: 1.6, rms: 0.0015)          // pre-roll + reply + 0.5 s tail
        addVoice(&buffer, at: 0.75, seconds: 0.3, amplitude: 0.012)
        XCTAssertLessThan(average(buffer), 0.005)
        XCTAssertTrue(PipelineController.hasSpeech(buffer))
    }

    func testShortReplyAfterTheToneIsSpeech() {
        var buffer = noise(seconds: 1.8, rms: 0.0015)
        addVoice(&buffer, at: 0.3, seconds: 0.42, amplitude: 0.008)  // tone heard by the mic
        addVoice(&buffer, at: 0.95, seconds: 0.3, amplitude: 0.012)  // "có"
        XCTAssertLessThan(average(buffer), 0.005)
        XCTAssertTrue(PipelineController.hasSpeech(buffer))
    }

    /// The tone alone, on time or 200 ms late (Bluetooth), in a short hold.
    func testShortHoldWithOnlyTheToneIsNotSpeech() {
        for at in [0.3, 0.5] {
            var buffer = noise(seconds: 1.5, rms: 0.0015)
            addVoice(&buffer, at: at, seconds: 0.42, amplitude: 0.01)
            XCTAssertLessThan(average(buffer), 0.005)
            XCTAssertFalse(PipelineController.hasSpeech(buffer), "tone at \(at) s")
        }
    }

    func testAShortThumpIsNotSpeech() {
        var buffer = noise(seconds: 2, rms: 0.0015, seed: 3)
        let thump = noise(seconds: 0.12, rms: 0.01, seed: 4)
        for (i, v) in thump.enumerated() { buffer[16000 + i] += v }
        XCTAssertFalse(PipelineController.hasSpeech(buffer))
    }

    func testEmptyAndTinyBuffersAreNotSpeech() {
        XCTAssertFalse(PipelineController.hasSpeech([]))
        XCTAssertFalse(PipelineController.hasSpeech([Float](repeating: 0.5, count: 100)))
    }
}
