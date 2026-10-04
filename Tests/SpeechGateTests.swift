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

    /// A chime like the real start tone: two partials, decaying. Its waveform
    /// is nothing like a voice, which is what the gate relies on.
    private func chime(seconds: Double = 0.42) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in
            let t = Float(i) / Float(rate)
            return exp(-4 * t) * (sin(2 * .pi * 1320 * t) + 0.6 * sin(2 * .pi * 1760 * t)) / 1.6
        }
    }

    private func addTone(_ buffer: inout [Float], at: Double, amplitude: Float) {
        let start = Int(at * Double(rate))
        for (i, v) in chime().enumerated() where start + i < buffer.count { buffer[start + i] += v * amplitude }
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
        addTone(&buffer, at: 0.3, amplitude: 0.08)
        XCTAssertLessThan(average(buffer), 0.005)
        XCTAssertFalse(PipelineController.hasSpeech(buffer, tone: chime()))
    }

    func testScatteredClicksAreNotSpeech() {
        // Start tone plus short clicks: enough frames in total, none of them a syllable.
        var buffer = noise(seconds: 30, rms: 0.0015)
        addTone(&buffer, at: 0.3, amplitude: 0.08)
        for k in 0..<10 { addVoice(&buffer, at: 5 + Double(k) * 2, seconds: 0.09, amplitude: 0.02) }
        XCTAssertLessThan(average(buffer), 0.005)
        XCTAssertFalse(PipelineController.hasSpeech(buffer, tone: chime()))
    }

    /// 29/09: "Nói ngắn ra thì nó không nghe". A one-word reply said softly:
    /// 0.3.11 required 0.6 s of voice and dropped it unless the mic also heard
    /// the start tone.
    func testShortSoftReplyIsSpeech() {
        for (tone, at) in [(nil, 0.75), (chime(), 0.75), (chime(), 0.55)] as [([Float]?, Double)] {
            var buffer = noise(seconds: 1.6, rms: 0.0015)          // pre-roll + reply + 0.5 s tail
            addVoice(&buffer, at: at, seconds: 0.3, amplitude: 0.012)
            XCTAssertLessThan(average(buffer), 0.005)
            XCTAssertTrue(PipelineController.hasSpeech(buffer, tone: tone), "reply at \(at) s, tone \(tone != nil)")
        }
    }

    /// Review r1: a reply starting where the tone would (0.55 s) with no tone
    /// in the mic must not be mistaken for it.
    func testShortReplyAfterTheToneIsSpeech() {
        var buffer = noise(seconds: 1.8, rms: 0.0015)
        addTone(&buffer, at: 0.3, amplitude: 0.02)
        addVoice(&buffer, at: 0.95, seconds: 0.3, amplitude: 0.012)  // "có"
        XCTAssertLessThan(average(buffer), 0.005)
        XCTAssertTrue(PipelineController.hasSpeech(buffer, tone: chime()))
    }

    /// Review r2: a reply said just before or just after the tone, the tone in
    /// the mic too — the reply must not inherit the tone's match. A reply said
    /// entirely over the tone (starting 0.30–0.55 s here) merges with it and is
    /// still dropped, as it was in 0.3.11; separating the two needs the tone
    /// subtracted, which is not measured on a real mic yet.
    func testShortReplyNextToTheToneIsSpeech() {
        for at in [0.0, 0.2, 0.6, 0.8] {
            var buffer = noise(seconds: 2.0, rms: 0.0015)
            addTone(&buffer, at: 0.3, amplitude: 0.02)
            addVoice(&buffer, at: at, seconds: 0.3, amplitude: 0.012)
            XCTAssertLessThan(average(buffer), 0.005)
            XCTAssertTrue(PipelineController.hasSpeech(buffer, tone: chime()), "reply at \(at) s")
        }
    }

    /// The tone alone in a short hold — on time, 200 ms and 450 ms late
    /// (Bluetooth), and after a short burst that used to use up the one skip.
    func testShortHoldWithOnlyTheToneIsNotSpeech() {
        for at in [0.3, 0.5, 0.75] {
            var buffer = noise(seconds: 1.8, rms: 0.0015)
            addTone(&buffer, at: at, amplitude: 0.03)
            XCTAssertLessThan(average(buffer), 0.005)
            XCTAssertFalse(PipelineController.hasSpeech(buffer, tone: chime()), "tone at \(at) s")
        }
        var buffer = noise(seconds: 1.8, rms: 0.0015)
        addVoice(&buffer, at: 0.22, seconds: 0.18, amplitude: 0.012)
        addTone(&buffer, at: 0.5, amplitude: 0.03)
        XCTAssertFalse(PipelineController.hasSpeech(buffer, tone: chime()), "burst + tone")
    }

    /// Sound on but the tone's samples could not be loaded: only the 0.6 s rule.
    func testUnreadableToneFallsBackToTheLongRule() {
        var buffer = noise(seconds: 1.6, rms: 0.0015)
        addVoice(&buffer, at: 0.75, seconds: 0.3, amplitude: 0.012)
        XCTAssertFalse(PipelineController.hasSpeech(buffer, tone: []))
    }

    func testAShortThumpIsNotSpeech() {
        var buffer = noise(seconds: 2, rms: 0.0015, seed: 3)
        let thump = noise(seconds: 0.12, rms: 0.01, seed: 4)
        for (i, v) in thump.enumerated() { buffer[16000 + i] += v }
        XCTAssertFalse(PipelineController.hasSpeech(buffer, tone: chime()))
    }

    func testEmptyAndTinyBuffersAreNotSpeech() {
        XCTAssertFalse(PipelineController.hasSpeech([]))
        XCTAssertFalse(PipelineController.hasSpeech([Float](repeating: 0.5, count: 100)))
    }
}
