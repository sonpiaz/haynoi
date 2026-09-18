import XCTest
@testable import Haynoi

final class CaptionLayoutTests: XCTestCase {

    func testEmpty() {
        let parts = CaptionLayout.split("  ")
        XCTAssertEqual(parts.committed, "")
        XCTAssertEqual(parts.fresh, "")
    }

    func testShortPhraseIsAllFresh() {
        let parts = CaptionLayout.split("Let's make the")
        XCTAssertEqual(parts.committed, "")
        XCTAssertEqual(parts.fresh, "Let's make the")
    }

    func testVideoFrameFourSplit() {
        // ~/.watch/960d0b1a2bc6 frame_04: "That looks great." regular + "Let's make the" bold.
        let parts = CaptionLayout.split("That looks great. Let's make the")
        XCTAssertEqual(parts.committed, "That looks great.")
        XCTAssertEqual(parts.fresh, "Let's make the")
    }

    func testSentenceEndCommitsAll() {
        let parts = CaptionLayout.split("That looks great.")
        XCTAssertEqual(parts.committed, "That looks great.")
        XCTAssertEqual(parts.fresh, "")
    }

    func testVietnameseLockDoesNotRecastCommitted() {
        let first = CaptionLayout.advanceLock(raw: "xin chào các bạn đang", locked: "")
        XCTAssertEqual(first.committed, "xin chào")
        XCTAssertEqual(first.fresh, "các bạn đang")
        let next = CaptionLayout.advanceLock(
            raw: "xin chào các bạn đang nói",
            locked: first.newLock
        )
        XCTAssertEqual(next.committed, "xin chào")
        XCTAssertEqual(next.fresh, "các bạn đang nói")
        XCTAssertEqual(next.newLock, "xin chào")
    }

    func testLockResetsWhenPrefixIsGone() {
        let next = CaptionLayout.advanceLock(raw: "Hay Nội đang chạy nhanh", locked: "xin chào")
        XCTAssertEqual(next.committed, "Hay Nội")
        XCTAssertEqual(next.fresh, "đang chạy nhanh")
    }

    func testPillWidthCapsAtFractionOfScreen() {
        let long = String(repeating: "chào ", count: 80)
        let width = CaptionLayout.pillWidth(for: long, screenWidth: 1728)
        XCTAssertEqual(width, 1728 * 0.56, accuracy: 0.5)
        let short = CaptionLayout.pillWidth(for: "", screenWidth: 1728)
        XCTAssertEqual(short, CaptionLayout.minWidth)
    }
}
