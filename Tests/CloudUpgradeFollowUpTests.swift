import XCTest
@testable import Haynoi

/// After the 2.5s deadline we keep Apple Speech on screen. Quality may still
/// arrive: replace only when the pasted span is intact.
final class CloudUpgradeFollowUpTests: XCTestCase {

    func testCloudArrivingAfterFourSecondsReplacesWhenSpanIntact() async {
        let started = Date()
        let cloud: Result<String, Error> = await withCheckedContinuation { cont in
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                cont.resume(returning: .success("quality transcript of the full sentence"))
            }
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3.9)
        XCTAssertTrue(
            PipelineController.cloudUpgradeDecision(
                cloud: cloud,
                onDeviceInserted: "few apple words",
                sameApp: true,
                spanStillMatches: true
            )
        )
    }

    func testCloudErrorKeepsOnDeviceText() {
        XCTAssertFalse(
            PipelineController.cloudUpgradeDecision(
                cloud: .failure(STTError.serverError("upstream_unavailable")),
                onDeviceInserted: "apple speech text",
                sameApp: true,
                spanStillMatches: true
            )
        )
        XCTAssertFalse(
            PipelineController.cloudUpgradeDecision(
                cloud: .failure(URLError(.timedOut)),
                onDeviceInserted: "apple speech text",
                sameApp: true,
                spanStillMatches: true
            )
        )
    }

    func testUserTypingOrAppSwitchBlocksReplace() {
        let cloud: Result<String, Error> = .success("quality transcript")
        XCTAssertFalse(
            PipelineController.cloudUpgradeDecision(
                cloud: cloud,
                onDeviceInserted: "apple speech text",
                sameApp: true,
                spanStillMatches: false
            ),
            "user typed over the pasted span"
        )
        XCTAssertFalse(
            PipelineController.cloudUpgradeDecision(
                cloud: cloud,
                onDeviceInserted: "apple speech text",
                sameApp: false,
                spanStillMatches: true
            ),
            "user switched apps"
        )
    }

    func testDeadlineConstantUnchanged() {
        XCTAssertEqual(PipelineController.cloudDeadline, 2.5, accuracy: 0.001)
    }
}
