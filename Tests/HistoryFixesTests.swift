import XCTest
@testable import Haynoi

/// History must say what Haynoi corrected on its own, and must keep reading
/// the entries written before this feature existed.
final class HistoryFixesTests: XCTestCase {

    private func decode(_ json: String) throws -> Transcription {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Transcription.self, from: Data(json.utf8))
    }

    func testOldEntryWithoutFixesStillDecodes() throws {
        let old = """
        {"id":"\(UUID().uuidString)","text":"xin chào","timestamp":"2026-09-01T10:00:00Z"}
        """
        let entry = try decode(old)
        XCTAssertEqual(entry.text, "xin chào")
        XCTAssertNil(entry.fixes, "an entry written before this feature has no fixes, not an empty list")
    }

    func testFixesRoundTrip() throws {
        let entry = Transcription(text: "Kyma API",
                                  fixes: [.init(wrong: "Keyma", right: "Kyma")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Transcription.self, from: encoder.encode(entry))
        XCTAssertEqual(back.fixes, [.init(wrong: "Keyma", right: "Kyma")])
    }

    func testNoFixesIsStoredAsNothing() {
        XCTAssertNil(Transcription(text: "a", fixes: []).fixes,
                     "a dictation where no rule fired must not carry an empty list into history.json")
        XCTAssertNil(Transcription(text: "a").fixes)
    }

    func testRowReadsOneFixInFullAndCountsTheRest() {
        let one: [Transcription.Fix] = [.init(wrong: "Keyma", right: "Kyma")]
        XCTAssertEqual(HistoryRow.fixLabel(for: one), "fixed Keyma → Kyma")

        let two = one + [.init(wrong: "Hanoi", right: "Haynoi")]
        XCTAssertEqual(HistoryRow.fixLabel(for: two), "fixed 2 words")
        XCTAssertEqual(HistoryRow.fixTooltip(for: two), "Keyma → Kyma\nHanoi → Haynoi")
    }
}
