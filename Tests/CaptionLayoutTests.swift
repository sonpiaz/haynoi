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
        let locked = CaptionLayout.advanceLock(raw: "That looks great.", locked: "That looks")
        XCTAssertEqual(locked.committed, "That looks great.")
        XCTAssertEqual(locked.fresh, "")
    }

    func testVietnameseLockGrowsAndKeepsCommittedStill() {
        let first = CaptionLayout.advanceLock(raw: "xin chào các bạn đang", locked: "")
        XCTAssertEqual(first.committed, "xin chào")
        XCTAssertEqual(first.fresh, "các bạn đang")
        // 6 words → last 3 bold, lock grows so earlier tokens are not recast.
        let next = CaptionLayout.advanceLock(
            raw: "xin chào các bạn đang nói",
            locked: first.newLock
        )
        XCTAssertEqual(next.committed, "xin chào các")
        XCTAssertEqual(next.fresh, "bạn đang nói")
        XCTAssertEqual(next.newLock, "xin chào các")
        XCTAssertTrue(next.committed.hasPrefix(first.newLock))
    }

    func testLockResetsWhenPrefixIsGone() {
        let next = CaptionLayout.advanceLock(raw: "Hay Nội đang chạy nhanh", locked: "xin chào")
        XCTAssertEqual(next.committed, "Hay Nội")
        XCTAssertEqual(next.fresh, "đang chạy nhanh")
    }

    func testPillWidthIsFixedNotGrownByText() {
        let long = String(repeating: "chào ", count: 80)
        let empty = CaptionLayout.pillWidth(for: "", screenWidth: 1728)
        let filled = CaptionLayout.pillWidth(for: long, screenWidth: 1728)
        XCTAssertEqual(empty, filled)
        XCTAssertEqual(empty, CaptionLayout.fixedWidth(screenWidth: 1728))
        // 1728 * 0.24 = 414.72 → 415, inside 360...420
        XCTAssertEqual(empty, 415, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(CaptionLayout.fixedWidth(screenWidth: 1000), CaptionLayout.minWidth)
        XCTAssertLessThanOrEqual(CaptionLayout.fixedWidth(screenWidth: 3000), CaptionLayout.maxWidth)
    }
}
