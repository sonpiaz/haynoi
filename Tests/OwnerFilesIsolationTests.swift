import XCTest
@testable import Haynoi

/// Every file of the owner's follows the dictionary's folder policy. history.json,
/// insights.json and failed/ were hardcoded to `Application Support/Haynoi`, so a
/// Debug build (and the test host) read and wrote the owner's real history — the
/// shape of the dictionary wipe on 2026-09-17. W37-1406.
@MainActor
final class OwnerFilesIsolationTests: XCTestCase {

    func testReleaseDebugAndTestsResolveToDifferentFolders() {
        let release = PersonalDictionary.supportDirectory(bundleIdentifier: "com.sonpiaz.haynoi", isRunningTests: false)
        let debug = PersonalDictionary.supportDirectory(bundleIdentifier: "com.sonpiaz.haynoi.dev", isRunningTests: false)
        let tests = PersonalDictionary.supportDirectory(bundleIdentifier: "com.sonpiaz.haynoi", isRunningTests: true)

        XCTAssertTrue(release.path.hasSuffix("/Application Support/Haynoi"), release.path)
        XCTAssertTrue(debug.path.hasSuffix("/Application Support/Haynoi-Dev"), debug.path)
        XCTAssertTrue(tests.path.hasPrefix(FileManager.default.temporaryDirectory.path), tests.path)
    }

    func testHistoryFollowsTheSamePolicy() {
        XCTAssertEqual(
            AppState.defaultHistoryFileURL(bundleIdentifier: "com.sonpiaz.haynoi.dev", isRunningTests: false),
            PersonalDictionary.supportDirectory(bundleIdentifier: "com.sonpiaz.haynoi.dev", isRunningTests: false)
                .appendingPathComponent("history.json")
        )
        XCTAssertTrue(AppState.defaultHistoryFileURL(bundleIdentifier: "com.sonpiaz.haynoi", isRunningTests: false)
            .path.hasSuffix("/Application Support/Haynoi/history.json"))
    }

    /// This process is the test host: nothing it resolves may land in the owner's folder.
    func testTheTestHostNeverResolvesTheOwnersFolder() {
        let owner = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haynoi", isDirectory: true).path
        for url in [AppState.defaultHistoryFileURL(), UsageTracker.insightsFileURL,
                    FailedDictationStore.failedDirectory, PasteStats.defaultFileURL()] {
            XCTAssertFalse(url.path.hasPrefix(owner + "/") || url.path == owner, "\(url.path) is the owner's folder")
        }
    }

    /// No new file may hardcode the folder again.
    func testNoSourceHardcodesTheSupportFolder() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files where file.lastPathComponent != "PersonalDictionary.swift" {
            let src = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(src.contains(".applicationSupportDirectory"),
                           "\(file.lastPathComponent) resolves Application Support itself; use PersonalDictionary.supportDirectory()")
        }
    }
}
