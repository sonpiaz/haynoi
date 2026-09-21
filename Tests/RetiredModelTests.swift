import XCTest
@testable import Haynoi

/// A model that stops answering does not break the build or raise an error — the
/// feature simply goes quiet. gemini-2.5-flash retires upstream on 2026-10-20; it
/// was named in the rewrite call, which serves both the email rewrite and the
/// grounded correction pass that runs during ordinary dictation.
final class RetiredModelTests: XCTestCase {

    /// name → the day it stops answering.
    private let retired = ["gemini-2.5-flash": "2026-10-20"]

    /// The first version of this checked only lines containing `"model"`, which
    /// caught exactly the shape it was written against: a literal on the same
    /// line. A review moved the name into a constant and the check stayed green
    /// while the app still asked for a dead model. It now looks for the name
    /// anywhere outside a comment, so a constant, a struct field and a two-line
    /// call all trip it. Measured by a review: five of the eight shapes it tried.
    ///
    /// What it still cannot see: a name split across a concatenation, a name
    /// assembled at runtime, and anything behind a server-side alias — `transcribe-quality` is resolved by the server, and
    /// the model behind it has its own retirement date. That needs the catalog,
    /// not the source.
    func testNoSourceStillNamesARetiredModel() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no sources found at \(sources.path)")

        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                // A comment explaining the move is fine; code asking for it is
                // not — including the trailing comment on a line of code, which
                // is the first thing the next person is likely to write.
                let code = String(line.prefix(while: { _ in true }))
                    .components(separatedBy: "//").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard !code.isEmpty else { continue }
                for (name, date) in retired where code.contains(name) {
                    XCTFail("\(file.lastPathComponent) still names \(name), which stops answering \(date): \(code)")
                }
            }
        }
    }
}
