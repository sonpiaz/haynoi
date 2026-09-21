import XCTest
@testable import Haynoi

/// A model that stops answering does not break the build or raise an error — the
/// feature simply goes quiet. gemini-2.5-flash retires upstream on 2026-10-20;
/// it was named in the rewrite call, which serves both the email rewrite and the
/// grounded correction pass that runs during ordinary dictation.
final class RetiredModelTests: XCTestCase {

    /// name → the day it stops answering.
    private let retired = ["gemini-2.5-flash": "2026-10-20"]

    func testNoRequestStillAsksForARetiredModel() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no sources found at \(sources.path)")

        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                // Only a request body counts; the comment explaining the move is fine.
                guard line.contains("\"model\"") else { continue }
                for (name, date) in retired where line.contains("\"\(name)\"") {
                    XCTFail("\(file.lastPathComponent) still asks for \(name), which stops answering \(date)")
                }
            }
        }
    }
}
