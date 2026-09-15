import XCTest
@testable import Haynoi

/// Email mode runs a second model pass. That pass used to throw on timeout/401
/// and drop the STT text. The original words must still be pasted.
final class EmailRewriteKeepsRawTests: XCTestCase {

    func testRewriteTimeoutKeepsOriginalTranscript() async {
        let original = "xin chào đây là bản thử"
        let kept = await STTProvider.keepTranscriptIfRewriteFails(original) {
            throw URLError(.timedOut)
        }
        XCTAssertEqual(kept, original)
    }

    func testRewrite401KeepsOriginalTranscript() async {
        let original = "please send the report by Friday"
        let kept = await STTProvider.keepTranscriptIfRewriteFails(original) {
            throw STTError.sessionExpired
        }
        XCTAssertEqual(kept, original)
    }

    func testRewriteSuccessUsesPolishedText() async {
        let kept = await STTProvider.keepTranscriptIfRewriteFails("raw spoken") {
            "Please send the report by Friday."
        }
        XCTAssertEqual(kept, "Please send the report by Friday.")
    }

    func testEmptyRewriteResultKeepsOriginal() async {
        let original = "xin chào"
        let kept = await STTProvider.keepTranscriptIfRewriteFails(original) { "" }
        XCTAssertEqual(kept, original)
    }
}
