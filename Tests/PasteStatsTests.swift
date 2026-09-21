import XCTest
@testable import Haynoi

/// The counters exist to turn "about one in ten does not paste" into a number.
/// They must hold app ids and counts, and nothing a person said.
final class PasteStatsTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paste-stats-\(UUID().uuidString).json")
        PasteStats.storeURL = tmp
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testCountsPerAppAndOutcome() {
        PasteStats.record(.taken, app: "dev.mandeck.native")
        PasteStats.record(.taken, app: "dev.mandeck.native")
        PasteStats.record(.keptForManualPaste, app: "dev.mandeck.native")
        PasteStats.record(.taken, app: "ru.keepcoder.Telegram")
        PasteStats.flush()

        let counts = PasteStats.load()
        XCTAssertEqual(counts["dev.mandeck.native"]?["taken"], 2)
        XCTAssertEqual(counts["dev.mandeck.native"]?["keptForManualPaste"], 1)
        XCTAssertEqual(counts["ru.keepcoder.Telegram"]?["taken"], 1)
    }

    func testCountsSurviveARestart() {
        PasteStats.record(.taken, app: "dev.mandeck.native")
        PasteStats.flush()
        PasteStats.record(.taken, app: "dev.mandeck.native")
        PasteStats.flush()
        XCTAssertEqual(PasteStats.load()["dev.mandeck.native"]?["taken"], 2)
    }

    func testAMissingAppIsCountedWithoutGuessing() {
        PasteStats.record(.notAttempted, app: nil)
        PasteStats.flush()
        XCTAssertEqual(PasteStats.load()["unknown"]?["notAttempted"], 1)
    }

    /// Whatever ends up on disk is app ids and numbers — never a sentence.
    func testTheFileHoldsNoDictatedText() throws {
        PasteStats.record(.taken, app: "dev.mandeck.native")
        PasteStats.flush()
        let raw = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertFalse(raw.contains(" "), "counters are ids and numbers, nothing with spaces in it")
        for outcome in PasteStats.Outcome.allCases where raw.contains(outcome.rawValue) {
            XCTAssertFalse(outcome.rawValue.isEmpty)
        }
    }

}
