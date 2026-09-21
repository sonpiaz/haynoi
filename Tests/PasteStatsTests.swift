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
    /// Checking for spaces proved nothing: `JSONEncoder` writes none, so a file
    /// holding a one-word dictation passed. Check the shape instead.
    func testTheFileHoldsOnlyAppIdsAndCounts() throws {
        PasteStats.record(.taken, app: "dev.mandeck.native")
        PasteStats.record(.keptUserCopy, app: nil)
        PasteStats.flush()

        let raw = try Data(contentsOf: tmp)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let outcomes = Set(PasteStats.Outcome.allCases.map(\.rawValue))

        for (app, counts) in decoded {
            XCTAssertTrue(app == "unknown" || app.contains("."),
                          "a key that is not a bundle id could be anything: \(app)")
            let perOutcome = try XCTUnwrap(counts as? [String: Int],
                                           "values are counts, nothing else")
            for key in perOutcome.keys {
                XCTAssertTrue(outcomes.contains(key), "unexpected key on disk: \(key)")
            }
        }
    }

    /// Every call site has to name the app, or a count lands under "unknown" and
    /// the numbers stop meaning anything per app.
    func testEveryCallSitePassesABundleIdentifier() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var callSites = 0
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("PasteStats.record(") {
                callSites += 1
                XCTAssertTrue(line.contains("app:"), "a record without an app: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(callSites, 8, "the outcomes of insert() and replaceSpan()")
    }

    /// The counters must never be written next to the owner's real files from a
    /// debug build or a test run — the protection the dictionary got after it was
    /// wiped on 2026-09-17.
    func testCountersAreKeptOutOfTheRealFolderInDevAndInTests() {
        let live = PasteStats.defaultFileURL(bundleIdentifier: "com.sonpiaz.haynoi", isRunningTests: false)
        let dev = PasteStats.defaultFileURL(bundleIdentifier: "com.sonpiaz.haynoi.dev", isRunningTests: false)
        let underTest = PasteStats.defaultFileURL(bundleIdentifier: "com.sonpiaz.haynoi", isRunningTests: true)

        XCTAssertEqual(live.lastPathComponent, "paste-stats.json")
        XCTAssertEqual(live.deletingLastPathComponent().lastPathComponent, "Haynoi")
        XCTAssertEqual(dev.deletingLastPathComponent().lastPathComponent, "Haynoi-Dev")
        XCTAssertTrue(underTest.path.contains(NSTemporaryDirectory()),
                      "a test run writes to a temp directory, never to the owner's folder")
        XCTAssertNotEqual(live.path, dev.path)
        XCTAssertNotEqual(live.path, underTest.path)
    }
}
