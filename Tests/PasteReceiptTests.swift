import XCTest
import AppKit
@testable import Haynoi

/// Auto-paste used to report success without any evidence: in a terminal AX exposes
/// no focused text element, so the old check compared a nil value to a nil value and
/// called every paste a success — including the ones that never arrived, whose text
/// the restore timer then wiped off the clipboard.
///
/// These cover the evidence that replaced that check — a reader asking for the text —
/// and the three ways the first round of the fix could still have hurt the user
/// (cases PR51-R1-DUPLICATE, PR51-R1-NIL-TARGET, PR51-R1-CLIPBOARD-OWNERSHIP).
/// Everything runs on a private pasteboard; the user's clipboard is never touched.
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

    @discardableResult
    private func put(_ receipt: TextInserter.PasteReceipt) -> Int {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(receipt, forTypes: [.string])
        pb.writeObjects([item])
        return pb.changeCount
    }

    // MARK: - The evidence

    func testNothingIsServedUntilSomethingReadsTheClipboard() {
        let receipt = TextInserter.PasteReceipt("chào buổi sáng")
        put(receipt)
        XCTAssertFalse(receipt.wasServed, "writing to the clipboard is not a read")
    }

    func testAReadServesTheSentenceAndCountsAsEvidence() {
        let receipt = TextInserter.PasteReceipt("chào buổi sáng")
        put(receipt)
        XCTAssertEqual(pb.string(forType: .string), "chào buổi sáng")
        XCTAssertTrue(receipt.wasServed, "a reader taking the text is the evidence the app asked for it")
    }

    /// One ⌘V can read the clipboard more than once — Mandeck asks for file URLs
    /// before the terminal asks for the string. Both reads must see the sentence.
    func testSecondReadWithinTheSamePasteStillGetsTheText() {
        let receipt = TextInserter.PasteReceipt("hai lần đọc")
        put(receipt)
        XCTAssertEqual(pb.string(forType: .string), "hai lần đọc")
        XCTAssertEqual(pb.string(forType: .string), "hai lần đọc")
    }

    // MARK: - PR51-R1-CLIPBOARD-OWNERSHIP

    func testUnreadPasteLeavesTheSentenceForAManualPaste() {
        let receipt = TextInserter.PasteReceipt("không ai dán")
        let ours = put(receipt)
        XCTAssertTrue(TextInserter.leaveTextForManualPaste("không ai dán", on: pb, ourChangeCount: ours))
        XCTAssertEqual(pb.string(forType: .string), "không ai dán")
        // And it survives a second manual paste, unlike a one-shot promise.
        XCTAssertEqual(pb.string(forType: .string), "không ai dán")
    }

    /// The user copying something while a paste is pending owns the clipboard: their
    /// copy must survive, and the sentence stays in the history instead.
    func testACopyMadeWhileWaitingIsNeverOverwritten() {
        let receipt = TextInserter.PasteReceipt("câu đọc chính tả")
        let ours = put(receipt)
        pb.clearContents()
        pb.setString("người dùng vừa copy cái này", forType: .string)
        XCTAssertFalse(TextInserter.leaveTextForManualPaste("câu đọc chính tả", on: pb, ourChangeCount: ours))
        XCTAssertEqual(pb.string(forType: .string), "người dùng vừa copy cái này")
    }

    // MARK: - PR51-R1-NIL-TARGET

    func testPasteGateBlocksAnAppThatIsNoLongerTheOneWeRecordedAgainst() {
        XCTAssertEqual(TextInserter.pasteGate(targetPID: 501, frontmostPID: 501, frontmostIsHaynoi: false), .go)
        XCTAssertEqual(TextInserter.pasteGate(targetPID: 501, frontmostPID: 777, frontmostIsHaynoi: false), .blockWrongApp)
        XCTAssertEqual(TextInserter.pasteGate(targetPID: 501, frontmostPID: nil, frontmostIsHaynoi: false), .blockWrongApp)
    }

    func testPasteGateRefusesToPasteIntoHaynoiWhenNoTargetWasCaptured() {
        XCTAssertEqual(TextInserter.pasteGate(targetPID: nil, frontmostPID: 42, frontmostIsHaynoi: true), .blockUnknownTarget)
        XCTAssertEqual(TextInserter.pasteGate(targetPID: nil, frontmostPID: 42, frontmostIsHaynoi: false), .go)
    }

    // MARK: - PR51-R1-DUPLICATE

    /// A timeout proves nobody has read the clipboard *yet* — never that the first
    /// keystroke was discarded. Posting a second ⌘V on a timeout pastes the sentence
    /// twice whenever both events were merely queued behind a busy app, so the paste
    /// path posts exactly once. Re-adding a retry has to come with proof that the
    /// first event is dead.
    func testThePastePathPostsCommandVExactlyOnce() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Haynoi/Input/TextInserter.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let body = try XCTUnwrap(text.components(separatedBy: "private static func pasteViaClipboard").last)
            .components(separatedBy: "\n    static func leaveTextForManualPaste").first
        let posts = try XCTUnwrap(body).components(separatedBy: "await postCommandV()").count - 1
        XCTAssertEqual(posts, 1, "one paste attempt posts ⌘V once; a retry can duplicate the sentence")
    }
}
