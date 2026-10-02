import XCTest
@testable import Haynoi

/// W37-1391: replaceSpan ("fix that") used to answer "replaced in place" on
/// the strength of an AX success code, recording .axUnconfirmed and returning
/// true anyway. Electron apps accept that write and drop the text, so the
/// correction silently never happened. Every AX-success branch must now go
/// through confirmReplace, which reads the field back.
final class ReplaceSpanConfirmsTests: XCTestCase {
    private func code(of signature: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Haynoi/Input/TextInserter.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: signature))
        let rest = src[start.upperBound...]
        let body = rest[..<(rest.range(of: "\n    /// ")?.lowerBound ?? rest.endIndex)]
        return body.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testReplaceSpanNeverTrustsAnAXSuccessCode() throws {
        let body = try code(of: "static func replaceSpan(")
        XCTAssertEqual(body.components(separatedBy: "return await confirmReplace(").count - 1, 2,
                       "both AX write paths (selected text, value splice) settle through confirmReplace")
        XCTAssertFalse(body.contains(".axUnconfirmed"), "replaceSpan must not record unconfirmed and still claim success")
        XCTAssertEqual(body.components(separatedBy: "return true").count - 1, 1,
                       "the only other success is a paste the app actually took (paste-over-selection)")
    }

    func testConfirmReplaceReportsTrueOnlyForAChangedField() throws {
        let body = try code(of: "private static func confirmReplace(")
        XCTAssertTrue(body.contains("if axInsertionLanded(before: before, after: focusedElementValue(in: app))"))
        XCTAssertTrue(body.contains("copyToClipboardWithNotification(newText"))
        XCTAssertTrue(body.contains("return false"))
        XCTAssertFalse(TextInserter.axInsertionLanded(before: "a", after: "a"))
        XCTAssertFalse(TextInserter.axInsertionLanded(before: nil, after: nil))
        XCTAssertTrue(TextInserter.axInsertionLanded(before: "a", after: "ab"))
    }
}
