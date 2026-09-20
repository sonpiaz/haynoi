import XCTest
import AppKit
@testable import Haynoi

/// Auto-paste used to report success without any evidence: in a terminal AX exposes
/// no focused text element, so the old check compared a nil value to a nil value and
/// called every paste a success — including the ones that never arrived, whose text
/// was then wiped off the clipboard by the restore timer.
///
/// These cover the evidence that replaced that check: the target app reading the
/// clipboard. All of it runs on a private pasteboard, never the user's clipboard.
final class PasteReceiptTests: XCTestCase {

    private var pb: NSPasteboard!

    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: NSPasteboard.Name("com.haynoi.tests.receipt-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pb.releaseGlobally()
        pb = nil
        super.tearDown()
    }

    private func put(_ receipt: TextInserter.PasteReceipt) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(receipt, forTypes: [.string])
        pb.writeObjects([item])
    }

    func testNothingIsServedUntilSomethingReadsTheClipboard() {
        let receipt = TextInserter.PasteReceipt("chào buổi sáng")
        put(receipt)
        XCTAssertFalse(receipt.wasServed, "writing to the clipboard is not a paste")
    }

    func testAReadServesTheDictatedTextAndCountsAsAPaste() {
        let receipt = TextInserter.PasteReceipt("chào buổi sáng")
        put(receipt)
        XCTAssertEqual(pb.string(forType: .string), "chào buổi sáng")
        XCTAssertTrue(receipt.wasServed, "a reader taking the text is the proof a paste happened")
    }

    /// One ⌘V can read the clipboard more than once — Mandeck asks for file URLs
    /// before the terminal asks for the string. Both reads must see the sentence.
    func testSecondReadWithinTheSamePasteStillGetsTheText() {
        let receipt = TextInserter.PasteReceipt("hai lần đọc")
        put(receipt)
        XCTAssertEqual(pb.string(forType: .string), "hai lần đọc")
        XCTAssertEqual(pb.string(forType: .string), "hai lần đọc")
    }

    func testTextSurvivesOnTheClipboardWhenNobodyPastes() {
        let receipt = TextInserter.PasteReceipt("không ai dán")
        put(receipt)
        XCTAssertFalse(receipt.wasServed)
        // The dictated text is still there to be pasted by hand — the failure a user
        // can recover from, instead of a silent loss.
        XCTAssertEqual(pb.string(forType: .string), "không ai dán")
    }
}
