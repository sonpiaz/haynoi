import XCTest
@testable import Haynoi

/// v1.1 "fix that" correction-capture unit tests (Signal C).
/// @MainActor: some assertions call MainActor-isolated APIs (CorrectionDetector.suggestion).
@MainActor
final class CorrectionLearningTests: XCTestCase {

    // MARK: - §1.1 tolerant decode of v1 dictionary.json (no confirmations/fireCount)

    func testV1JSONDecodeDefaultsNewFieldsToZero() throws {
        // A v1 blob: predates confirmations/fireCount entirely.
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "right": "Hà Nội",
          "wrong": "Haynoi",
          "kind": "replacement",
          "source": "manual",
          "enabled": true,
          "caseSensitive": true,
          "frequency": 3,
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entry = try dec.decode(DictionaryEntry.self, from: json)

        XCTAssertEqual(entry.confirmations, 0, "v1 file must default confirmations to 0")
        XCTAssertEqual(entry.fireCount, 0, "v1 file must default fireCount to 0")
        XCTAssertEqual(entry.right, "Hà Nội")
        XCTAssertEqual(entry.wrong, "Haynoi")
        XCTAssertEqual(entry.frequency, 3)
    }

    func testV1ArrayDecodeRoundTrip() throws {
        // Array of v1 rows must decode without keyNotFound throwing.
        let json = """
        [
          {"id":"00000000-0000-0000-0000-000000000002","right":"Son","kind":"term","source":"manual","enabled":true,"caseSensitive":true,"frequency":0,"createdAt":"2026-01-01T00:00:00Z"}
        ]
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let entries = try dec.decode([DictionaryEntry].self, from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].confirmations, 0)
        XCTAssertEqual(entries[0].fireCount, 0)
    }

    // MARK: - §1.2 activation gate

    func testGateManualAlwaysFires() {
        let e = DictionaryEntry(right: "Y", wrong: "X", kind: .replacement, source: .manual)
        XCTAssertTrue(e.firesAsReplacement)
    }

    func testGateLearnedUnconfirmedDoesNotFire() {
        let e = DictionaryEntry(right: "Y", wrong: "X", kind: .replacement, source: .learned, confirmations: 1)
        XCTAssertFalse(e.firesAsReplacement, "learned conf<2 must not fire")
    }

    func testGateLearnedConfirmedFires() {
        let e = DictionaryEntry(right: "Y", wrong: "X", kind: .replacement, source: .learned, confirmations: 2)
        XCTAssertTrue(e.firesAsReplacement, "learned conf>=2 must fire")
    }

    func testGateDisabledNeverFires() {
        let e = DictionaryEntry(right: "Y", wrong: "X", kind: .replacement, source: .manual, enabled: false)
        XCTAssertFalse(e.firesAsReplacement)
    }

    func testGateTermNeverFiresAsReplacement() {
        let e = DictionaryEntry(right: "Son", kind: .term, source: .manual)
        XCTAssertFalse(e.firesAsReplacement)
    }

    // MARK: - §7.1 CorrectionDiff

    func testDiffSingleRegionLocalizedChange() {
        let change = CorrectionDiff.extractChange(from: "tôi đến Haynoi hôm nay",
                                                  to: "tôi đến Hà Nội hôm nay")
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.wrong, "Haynoi")
        XCTAssertEqual(change?.right, "Hà Nội")
    }

    func testDiffWholeSentenceRewriteFallsBackToWholeStrings() {
        let old = "the cat sat"
        let new = "a dog ran fast"
        let change = CorrectionDiff.extractChange(from: old, to: new)
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.wrong, old)
        XCTAssertEqual(change?.right, new)
    }

    func testDiffNoRealChangeReturnsNil() {
        XCTAssertNil(CorrectionDiff.extractChange(from: "same text", to: "same text"))
    }

    func testDiffPureInsertFallsBackToWholeStrings() {
        // No common-middle swap → whole strings (insert doesn't generalize).
        let change = CorrectionDiff.extractChange(from: "hello world", to: "hello there world")
        XCTAssertNotNil(change)
        XCTAssertEqual(change?.wrong, "hello world")
        XCTAssertEqual(change?.right, "hello there world")
    }

    // MARK: - §5.4 Signal B: short re-dictation must fire (whole-string floor bug)

    func testSignalBShortRedictationHaiNoiFires() {
        // The doc/header headline example. Whole-string sim is only ~0.57, so the
        // old 0.85 floor rejected it — now gated on the changed region instead.
        let s = CorrectionDetector.suggestion(from: "Hai Noi", to: "Hà Nội")
        XCTAssertNotNil(s, "'Hai Noi' → 'Hà Nội' is the headline case and must fire")
        XCTAssertEqual(s?.right, "Hà Nội")
    }

    func testSignalBShortRedictationSonFires() {
        let s = CorrectionDetector.suggestion(from: "Son", to: "Sơn")
        XCTAssertNotNil(s, "'Son' → 'Sơn' (adds diacritic) must fire")
        XCTAssertEqual(s?.right, "Sơn")
    }

    func testSignalBHaynoiToHaNoiFires() {
        let s = CorrectionDetector.suggestion(from: "Haynoi", to: "Hà Nội")
        XCTAssertNotNil(s, "'Haynoi' → 'Hà Nội' must fire")
        XCTAssertEqual(s?.right, "Hà Nội")
    }

    func testSignalBUnrelatedDifferentWordRejected() {
        // Loose whole-string floor must still reject two genuinely different words
        // (not a near-homophone re-dictation).
        XCTAssertNil(CorrectionDetector.suggestion(from: "mèo", to: "Hà Nội"),
                     "different word must not be suggested as a correction")
    }

    func testSignalBStripDiacriticsNeverSuggested() {
        // Directionality guard: re-dictation that STRIPS diacritics is the
        // self-poisoning direction and must never fire.
        XCTAssertNil(CorrectionDetector.suggestion(from: "Sơn", to: "Son"))
    }

    // MARK: - §7.3 self-heal: disable a fired rule the user reversed

    func testSelfHealDisablesMatchingReplacement() {
        let dict = PersonalDictionary.shared
        // Seed a learned, confirmed rule X→Y.
        let upserted = dict.upsertLearnedReplacement(wrong: "selfHealX",
                                                     right: "selfHealY",
                                                     confirmations: 2)
        XCTAssertNotNil(upserted)
        XCTAssertNotNil(dict.enabledReplacement(matching: "selfHealX", right: "selfHealY"))

        // User reverses it → disable.
        let disabledID = dict.disableMatchingReplacement(wrong: "selfHealX", right: "selfHealY")
        XCTAssertNotNil(disabledID)
        XCTAssertNil(dict.enabledReplacement(matching: "selfHealX", right: "selfHealY"),
                     "disabled rule must no longer be returned as enabled")

        // Cleanup so the test doesn't pollute the real dictionary.
        if let id = disabledID { dict.delete(id: id) }
    }
}
