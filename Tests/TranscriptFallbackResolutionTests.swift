import XCTest
@testable import Haynoi

final class TranscriptFallbackResolutionTests: XCTestCase {

    func testCloudSuccessWithinDeadlineWins() {
        let resolved = PipelineController.resolveTranscript(
            cloud: .success("cloud text"),
            deadlineExceeded: false,
            onDevice: "on device text"
        )
        XCTAssertEqual(resolved?.text, "cloud text")
        XCTAssertEqual(resolved?.source, .cloud)
    }

    func testOutOfCreditsFallsBackToOnDevice() {
        let resolved = PipelineController.resolveTranscript(
            cloud: .failure(STTError.outOfCredits),
            deadlineExceeded: false,
            onDevice: "on device text"
        )
        XCTAssertEqual(resolved?.text, "on device text")
        XCTAssertEqual(resolved?.source, .onDevice)
    }

    func testServerErrorFallsBackToOnDevice() {
        let resolved = PipelineController.resolveTranscript(
            cloud: .failure(STTError.serverError("upstream_unavailable")),
            deadlineExceeded: false,
            onDevice: "on device text"
        )
        XCTAssertEqual(resolved?.text, "on device text")
        XCTAssertEqual(resolved?.source, .onDevice)
    }

    func testDeadlineExceededFallsBackToOnDevice() {
        let resolved = PipelineController.resolveTranscript(
            cloud: nil,
            deadlineExceeded: true,
            onDevice: "on device text"
        )
        XCTAssertEqual(resolved?.text, "on device text")
        XCTAssertEqual(resolved?.source, .onDevice)
    }

    func testCloudFailureAndNoOnDeviceReturnsNil() {
        let resolved = PipelineController.resolveTranscript(
            cloud: .failure(STTError.serverError("upstream_unavailable")),
            deadlineExceeded: false,
            onDevice: "   "
        )
        XCTAssertNil(resolved)
    }

    func testCloudDeadlineIsTwoAndAHalfSeconds() {
        XCTAssertEqual(PipelineController.cloudDeadline, 2.5, accuracy: 0.001)
    }

    func testNoConnectionFallsBackToOnDevice() {
        let resolved = PipelineController.resolveTranscript(
            cloud: .failure(STTError.noConnection),
            deadlineExceeded: false,
            onDevice: "on device text"
        )
        XCTAssertEqual(resolved?.text, "on device text")
        XCTAssertEqual(resolved?.source, .onDevice)
    }
}

