import XCTest
@testable import Haynoi

/// v2 Phase 4: phonetic keys, doubtful-word reconstruction, dictionary
/// candidates, and the Signal B phonetic widening.
@MainActor
final class PhoneticsTests: XCTestCase {

    // MARK: - Keys

    func testSoundAlikeSpellingsShareAKey() {
        // The real confusion pairs this feature exists for.
        XCTAssertEqual(Phonetics.key(for: "Sơn"), Phonetics.key(for: "Sun"))
        XCTAssertEqual(Phonetics.key(for: "Sơn"), Phonetics.key(for: "Son"))
        XCTAssertEqual(Phonetics.key(for: "Hà Nội"), Phonetics.key(for: "Haynoi"))
        XCTAssertEqual(Phonetics.key(for: "Hà Nội"), Phonetics.key(for: "Hai Noi"))
        XCTAssertEqual(Phonetics.key(for: "Affitor"), Phonetics.key(for: "Afider"))
        XCTAssertEqual(Phonetics.key(for: "Xero"), Phonetics.key(for: "Zero"))
        XCTAssertEqual(Phonetics.key(for: "Eric"), Phonetics.key(for: "Erik"))
        XCTAssertEqual(Phonetics.key(for: "Mandeck"), Phonetics.key(for: "Mandec"))
        // VN tr/ch merge — tone- and vowel-quality-insensitive by design.
        XCTAssertEqual(Phonetics.key(for: "trương"), Phonetics.key(for: "chương"))
    }

    func testDifferentWordsStayApart() {
        XCTAssertFalse(Phonetics.close("mèo", "Hà Nội"))
        XCTAssertFalse(Phonetics.close("cat", "dog"))
        XCTAssertFalse(Phonetics.close("", "Sơn"))
    }

    // MARK: - Doubtful-word reconstruction (real measured token stream)

    func testDoubtfulWordsFromMeasuredTokenStream() {
        // Verbatim from the 2026-08-29 live measurement. Floor is -0.3.
        let tokens: [STTProvider.TokenLogprob] = [
            .init(token: " for", logprob: -0.0000),
            .init(token: " Hanoi", logprob: -0.0061),   // confidently WRONG — invisible here
            .init(token: ".", logprob: -0.0000),
            .init(token: " My", logprob: -0.0000),
            .init(token: " Sun", logprob: -0.9093),      // doubtful
            .init(token: " building", logprob: -0.0000),
            .init(token: " Mand", logprob: -0.2523),
            .init(token: "ec", logprob: -0.4039),        // same word, doubtful token
            .init(token: " and", logprob: -0.0006),
            .init(token: " Af", logprob: -0.3689),
            .init(token: "iter", logprob: -1.1107),
            .init(token: ".", logprob: -0.0000),
        ]
        let doubtful = STTProvider.doubtfulWords(from: tokens)
        XCTAssertEqual(doubtful, ["Sun", "Mandec", "Afiter"],
                       "multi-token words reassemble, punctuation trims, confident words stay out")
    }

    func testDoubtfulWordsEmptyWhenAllConfident() {
        let tokens: [STTProvider.TokenLogprob] = [
            .init(token: "This", logprob: -0.0002),
            .init(token: " is", logprob: 0.0),
        ]
        XCTAssertTrue(STTProvider.doubtfulWords(from: tokens).isEmpty)
    }

    // MARK: - Dictionary candidates

    func testPhoneticCandidatesMatchDictionaryTerms() {
        let dict = PersonalDictionary.shared
        var cleanup: [UUID] = []
        defer { cleanup.forEach { dict.delete(id: $0) } }
        if let e = dict.addTerm("PhonCandAffitor") { cleanup.append(e.id) }

        XCTAssertTrue(dict.phoneticCandidates(for: "foncandafider").contains("PhonCandAffitor"),
                      "a sound-alike misrecognition finds the dictionary term")
        XCTAssertTrue(dict.phoneticCandidates(for: "zzqqxx").isEmpty)
    }

    // MARK: - Hint section in the correction prompt

    func testHintsRenderIntoSystemPrompt() {
        let system = STTProvider.rewriteSystemPrompt(
            base: "BASE", glossary: [], pairs: [],
            hints: [(heard: "Afiter", candidates: ["Affitor"])]
        )
        XCTAssertTrue(system.contains("\"Afiter\" → possibly Affitor"))
        XCTAssertTrue(system.contains("UNSURE"))
        XCTAssertTrue(system.hasSuffix("BASE"))
        // No hints → no section.
        XCTAssertFalse(STTProvider.rewriteSystemPrompt(base: "BASE", glossary: [], pairs: [])
            .contains("UNSURE"))
    }

    // MARK: - Signal B phonetic widening

    func testOrthographicallyFarButPhoneticallyEqualPairQualifies() {
        // Synthetic long name: joined edit distance exceeds the ortho cap (4),
        // but the phonetic keys agree within one slip — the widening path.
        // Direction gate satisfied: `right` adds a diacritic + a capital.
        XCTAssertTrue(CorrectionDetector.qualifiesAsLearnable(
            wrong: "kolaborayshun", right: "Collaborâtion"))
    }

    func testPhoneticWideningNeverBypassesDirectionGate() {
        // Same sounds, but `right` STRIPS the diacritic — the self-poisoning
        // direction must stay blocked no matter how close the phonetics are.
        XCTAssertFalse(CorrectionDetector.qualifiesAsLearnable(
            wrong: "Sơn", right: "Son"))
    }
}
