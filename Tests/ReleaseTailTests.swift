import XCTest
@testable import Haynoi

/// "nó thường thiếu cái chữ cái cuối cùng" (29/09): capture ended on key release,
/// and people release while the last word is still coming out. The pipeline now
/// keeps recording `tailMs` after release. evals/release-tail/ holds the audio
/// measurement behind the number.
@MainActor
final class ReleaseTailTests: XCTestCase {

    /// Audio ending 450 ms before the speech did dropped the last word on
    /// transcribe-quality; the tail has to cover that.
    func testTailCoversTheMeasuredLoss() {
        XCTAssertGreaterThanOrEqual(PipelineController.tailMs, 450)
        XCTAssertLessThanOrEqual(PipelineController.tailMs, 800, "every dictation waits this long before it is sent")
    }

    /// The tail must not turn a tap into a dictation: a 0 ms hold records only
    /// the 300 ms pre-roll plus the tail, and that is still no speech.
    func testTailDoesNotCountAsHeldTime() {
        let tail = Double(PipelineController.tailMs) / 1000
        let tapSamples = Int((0.3 + tail) * 16000)
        XCTAssertEqual(PipelineController.heldSeconds(sampleCount: tapSamples, tail: tail), 0, accuracy: 0.001)

        let twoSecondHold = Int((0.3 + 2.0 + tail) * 16000)
        XCTAssertEqual(PipelineController.heldSeconds(sampleCount: twoSecondHold, tail: tail), 2.0, accuracy: 0.001)

        // A tail cut short by the next press counts only what it recorded.
        XCTAssertEqual(PipelineController.heldSeconds(sampleCount: Int((0.3 + 1.0 + 0.1) * 16000), tail: 0.1), 1.0, accuracy: 0.001)
    }
}
