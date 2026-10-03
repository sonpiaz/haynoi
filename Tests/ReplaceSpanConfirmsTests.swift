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
    /// Grok note on 8b71c0a: the success dink played even when the replace was
    /// not confirmed, telling the user "fixed" while the old text stayed.
    func testFixThatDinkOnlyWhenReplacedInPlace() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Haynoi/App/PipelineController.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "let replacedInPlace = await TextInserter.replaceSpan("))
        let rest = src[start.upperBound...]
        let body = String(rest[..<(rest.range(of: "// MARK: - Device Abort Handler")?.lowerBound ?? rest.endIndex)])
        let tone = try XCTUnwrap(body.range(of: "SoundFeedback.shared.playSuccessTone()"))
        let guardLine = try XCTUnwrap(body[..<tone.lowerBound].range(of: "if replacedInPlace,", options: .backwards))
        XCTAssertFalse(body[guardLine.upperBound..<tone.lowerBound].contains("}"),
                       "the success tone sits inside the replacedInPlace guard")
    }
}
