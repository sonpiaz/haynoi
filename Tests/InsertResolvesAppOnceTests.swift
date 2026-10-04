import XCTest

/// W37-1391 (4): insert() used to resolve the target app in one step and
/// re-read the frontmost app in the next, so the caret read, the ⌘V and the AX
/// write could land on different apps if focus moved in between. It reads the
/// frontmost app once, right before the gate, and hands that down.
final class InsertResolvesAppOnceTests: XCTestCase {
    func testInsertReadsTheFrontmostAppOnce() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Haynoi/Input/TextInserter.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "static func insert(_ text: String"))
        let rest = src[start.upperBound...]
        let body = rest[..<(rest.range(of: "\n    static func ")?.lowerBound ?? rest.endIndex)]
        let code = body.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        XCTAssertEqual(code.components(separatedBy: "NSWorkspace.shared.frontmostApplication").count - 1, 1)
    }
}
