import XCTest
@testable import Haynoi

/// On-device SFSpeech (vi-VN, macOS 26.6.2) restarts `formattedString` after
/// every pause. Sequences below are copied from real callbacks, 18 Sep 2026:
/// the result that closes an utterance carries `speechRecognitionMetadata`,
/// the next partial holds only the new utterance.
final class InterimTranscriptTests: XCTestCase {

    private let first = "Hôm nay mình kiểm tra ứng dụng hãy nói xem chữ có chạy liên tục không"

    func testUtteranceResetKeepsEarlierWords() {
        var t = InterimTranscript()
        t.ingest("Hôm nay mình", endsUtterance: false)
        t.ingest(first, endsUtterance: false)
        t.ingest(first, endsUtterance: true)
        t.ingest("Câu", endsUtterance: false)
        t.ingest("Câu thứ 2", endsUtterance: false)
        XCTAssertEqual(t.text, first + " Câu thứ 2")
    }

    func testWholeHoldSurvivesSeveralPausesAndEmptyFinal() {
        var t = InterimTranscript()
        t.ingest(first, endsUtterance: true)
        t.ingest("Câu thứ 2 nói về kế hoạch", endsUtterance: false)
        t.ingest("Câu thứ 2 nói về kế hoạch tuần này", endsUtterance: true)
        t.ingest("Câu", endsUtterance: false)
        t.ingest("Câu cuối cùng cảm ơn mọi người", endsUtterance: true)
        // endAudio(): isFinal with an empty string.
        t.ingest("", endsUtterance: false)
        XCTAssertEqual(
            t.text,
            first + " Câu thứ 2 nói về kế hoạch tuần này Câu cuối cùng cảm ơn mọi người"
        )
    }

    func testRevisionInsideOneUtteranceReplaces() {
        var t = InterimTranscript()
        t.ingest("Câu thứ năm ngoái", endsUtterance: false)
        t.ingest("Câu thứ 5 nói về", endsUtterance: false)
        XCTAssertEqual(t.text, "Câu thứ 5 nói về")
    }

    /// If a recognizer marks the utterance but keeps the old words, do not
    /// print them twice.
    func testContinuationAfterMarkerDoesNotDuplicate() {
        var t = InterimTranscript()
        t.ingest("xin chào các bạn", endsUtterance: true)
        t.ingest("xin chào các bạn hôm nay", endsUtterance: false)
        XCTAssertEqual(t.text, "xin chào các bạn hôm nay")
    }

    func testCaptionTailKeepsRightEndOnWordBoundary() {
        let long = String(repeating: "chào ", count: 100) + "cuối"
        let tail = CaptionLayout.tail(long)
        XCTAssertLessThanOrEqual(tail.count, CaptionLayout.maxChars)
        XCTAssertTrue(tail.hasSuffix("chào cuối"))
        XCTAssertTrue(tail.hasPrefix("chào"))
        XCTAssertEqual(CaptionLayout.tail("ngắn"), "ngắn")
    }
}
