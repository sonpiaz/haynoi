import XCTest
@testable import Haynoi

/// The dictionary must survive a relaunch. v0.3.6–0.3.10 wrote ISO-8601 dates
/// and read them back as numbers, so every launch silently started empty and
/// the next write erased the file. These tests go through the real
/// persist() → load() path on a throwaway file, never a hand-built decoder.
final class PersonalDictionaryPersistenceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalDictionaryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testEntriesSurviveRelaunch() {
        let url = dir.appendingPathComponent("dictionary.json")
        let first = PersonalDictionary(fileURL: url)
        first.addTerm("Mandeck")
        first.upsertLearnedReplacement(wrong: "Keyma", right: "Kyma", confirmations: 2)

        let relaunched = PersonalDictionary(fileURL: url)
        XCTAssertEqual(relaunched.all.count, 2, "a relaunch must read back every entry persist() wrote")
        XCTAssertEqual(relaunched.learnedCount, 1)
        XCTAssertEqual(relaunched.applyReplacements(to: "Keyma API"), "Kyma API",
                       "a learned fix must still fire after a relaunch")
    }

    func testUnreadableFileIsMovedAsideNotOverwritten() throws {
        let url = dir.appendingPathComponent("dictionary.json")
        try Data("not json".utf8).write(to: url)

        let dict = PersonalDictionary(fileURL: url)
        XCTAssertTrue(dict.all.isEmpty)
        dict.addTerm("Mandeck") // persists — must not destroy the unreadable original

        let asides = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("dictionary.corrupt-") }
        XCTAssertEqual(asides.count, 1, "an unreadable file is kept aside, not overwritten")
        let kept = try Data(contentsOf: dir.appendingPathComponent(asides[0]))
        XCTAssertEqual(String(decoding: kept, as: UTF8.self), "not json")
    }

    func testTestRunsNeverTouchTheRealDictionary() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haynoi/dictionary.json")
        XCTAssertNotEqual(PersonalDictionary.shared.fileURL.standardizedFileURL, real.standardizedFileURL,
                          "tests wiped the user's real dictionary on 2026-09-01")
    }

    func testSupportFolderSplitsDevFromProduction() {
        XCTAssertEqual(
            PersonalDictionary.supportFolderName(bundleIdentifier: "com.sonpiaz.haynoi", isRunningTests: false),
            "Haynoi"
        )
        XCTAssertEqual(
            PersonalDictionary.supportFolderName(bundleIdentifier: "com.sonpiaz.haynoi.dev", isRunningTests: false),
            "Haynoi-Dev"
        )
        let prod = PersonalDictionary.defaultFileURL(
            bundleIdentifier: "com.sonpiaz.haynoi",
            isRunningTests: false
        )
        let dev = PersonalDictionary.defaultFileURL(
            bundleIdentifier: "com.sonpiaz.haynoi.dev",
            isRunningTests: false
        )
        XCTAssertTrue(PersonalDictionary.isProductionDictionaryURL(prod))
        XCTAssertFalse(PersonalDictionary.isProductionDictionaryURL(dev))
        XCTAssertTrue(dev.path.contains("Haynoi-Dev"))
        XCTAssertNotEqual(prod.standardizedFileURL, dev.standardizedFileURL)
    }

    func testDevPersistDoesNotChangeProductionFileBytes() throws {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haynoi/dictionary.json")
        let before = try Data(contentsOf: real)
        XCTAssertGreaterThan(before.count, 4, "P0 restore must already be on disk before this test")

        let devURL = dir.appendingPathComponent("Haynoi-Dev/dictionary.json")
        try FileManager.default.createDirectory(at: devURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dict = PersonalDictionary(fileURL: devURL)
        dict.addTerm("DevMustNotLeak")

        let after = try Data(contentsOf: real)
        XCTAssertEqual(before, after, "a Dev/test persist must not change the live dictionary")
        XCTAssertTrue(PersonalDictionary.isProductionDictionaryURL(real))
        XCTAssertFalse(PersonalDictionary.isProductionBundle(bundleIdentifier: "com.sonpiaz.haynoi.dev"))
        XCTAssertFalse(PersonalDictionary.isProductionBundle(bundleIdentifier: "com.sonpiaz.haynoiTests"))
    }
}
