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

    // MARK: - A running app must not overwrite a file that changed under it
    //
    // 2026-09-17 18:29: the live dictionary went 30 entries → empty while an
    // app that had loaded the empty file kept running; its next persist() wrote
    // its own stale memory over the restored file.

    private func writeEntries(_ entries: [DictionaryEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    private func readEntries(at url: URL) throws -> [DictionaryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DictionaryEntry].self, from: Data(contentsOf: url))
    }

    func testPersistKeepsEntriesRestoredWhileTheAppWasRunning() throws {
        let url = dir.appendingPathComponent("dictionary.json")
        let app = PersonalDictionary(fileURL: url)
        app.addTerm("Mandeck")

        // A backup is restored (or another build writes) while this app runs.
        let restored = (1...30).map { DictionaryEntry(right: "word\($0)", kind: .term) }
        try writeEntries(restored, to: url)

        app.addTerm("Pheme") // persists

        let onDisk = try readEntries(at: url)
        XCTAssertEqual(onDisk.count, 32, "the 30 restored rows must survive a stale app's save")
        XCTAssertTrue(onDisk.contains { $0.right == "word30" })
        XCTAssertTrue(onDisk.contains { $0.right == "Mandeck" })
        XCTAssertTrue(onDisk.contains { $0.right == "Pheme" })
        XCTAssertEqual(app.all.count, 32, "memory takes the rows back too, so the next save keeps them")
    }

    func testDeleteStillDeletesWhenTheFileChangedUnderUs() throws {
        let url = dir.appendingPathComponent("dictionary.json")
        let app = PersonalDictionary(fileURL: url)
        let alpha = app.addTerm("Alpha")!
        app.addTerm("Beta")

        var disk = try readEntries(at: url)
        disk.append(DictionaryEntry(right: "Gamma", kind: .term)) // added by something else
        try writeEntries(disk, to: url)

        app.delete(id: alpha.id)

        let onDisk = try readEntries(at: url)
        XCTAssertEqual(Set(onDisk.map(\.right)), ["Beta", "Gamma"],
                       "the deleted row stays deleted, the external row stays")
    }

    func testUntouchedFileIsWrittenWithoutMerging() throws {
        let url = dir.appendingPathComponent("dictionary.json")
        let app = PersonalDictionary(fileURL: url)
        app.addTerm("Alpha")
        app.addTerm("Beta")
        let onDisk = try readEntries(at: url)
        XCTAssertEqual(Set(onDisk.map(\.right)), ["Alpha", "Beta"])
    }

    func testGlossarySeesRowsRestoredWhileTheAppWasRunning() throws {
        let url = dir.appendingPathComponent("dictionary.json")
        let app = PersonalDictionary(fileURL: url)
        app.addTerm("Alpha")

        var disk = try readEntries(at: url)
        disk.append(DictionaryEntry(right: "Kyma", kind: .term))
        try writeEntries(disk, to: url)

        XCTAssertTrue(app.enabledEntries(kinds: [.term]).contains { $0.right == "Kyma" },
                      "a restore must reach the glossary at the next dictation, not at the next save")
        XCTAssertTrue(app.all.contains { $0.right == "Kyma" })
    }

    func testReadDoesNotResurrectADeletedRow() throws {
        let url = dir.appendingPathComponent("dictionary.json")
        let app = PersonalDictionary(fileURL: url)
        let alpha = app.addTerm("Alpha")!
        app.addTerm("Beta")
        app.delete(id: alpha.id)

        // Something else writes a file that still carries the deleted row.
        try writeEntries([
            DictionaryEntry(id: alpha.id, right: "Alpha", kind: .term),
            DictionaryEntry(right: "Beta", kind: .term),
        ], to: url)

        XCTAssertFalse(app.all.contains { $0.id == alpha.id }, "a deleted row stays deleted")
    }

    func testOneDictationUsesOnePhoneticSnapshot() throws {
        let url = dir.appendingPathComponent("dictionary.json")
        let app = PersonalDictionary(fileURL: url)
        app.addTerm("Affitor")
        let terms = app.phoneticCandidateTerms()

        var disk = try readEntries(at: url)
        disk.append(DictionaryEntry(right: "Mandeck", kind: .term))
        try writeEntries(disk, to: url)

        XCTAssertEqual(app.phoneticCandidates(for: "Afider", in: terms), ["Affitor"])
        XCTAssertEqual(app.phoneticCandidates(for: "Mandec", in: terms), [],
                       "hints for one dictation come from one snapshot, even if the file changes")
        XCTAssertEqual(app.phoneticCandidates(for: "Mandec"), ["Mandeck"],
                       "a fresh lookup still sees the row that appeared")
    }
}
