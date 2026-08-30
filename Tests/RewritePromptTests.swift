import XCTest
@testable import Haynoi

/// v2 Phase 1: correction pairs feed the LLM rewrite pass as grounded few-shot
/// context (redesign/10-DICTATION-LEARNING-V2.md). Covers the prompt builder,
/// the activation gate on `correctionPairs`, and the invariant that `wrong`
/// forms never leak into the STT-side glossary.
final class RewritePromptTests: XCTestCase {

    // MARK: - Prompt builder

    func testEmptyDictionaryLeavesBasePromptUntouched() {
        let base = "Clean up this dictated text."
        XCTAssertEqual(STTProvider.rewriteSystemPrompt(base: base, glossary: [], pairs: []), base)
    }

    func testGlossaryOnlyKeepsLegacyShape() {
        let system = STTProvider.rewriteSystemPrompt(
            base: "BASE", glossary: ["Haynoi", "Sơn"], pairs: []
        )
        XCTAssertTrue(system.contains("preferred spellings"), "glossary section must be present")
        XCTAssertTrue(system.contains("Haynoi, Sơn."))
        XCTAssertTrue(system.hasSuffix("BASE"), "mode prompt must come last")
        XCTAssertFalse(system.contains("misrecognitions"), "no pair section without pairs")
    }

    func testPairsRenderedAsGroundedFewShot() {
        let system = STTProvider.rewriteSystemPrompt(
            base: "BASE", glossary: ["Haynoi"],
            pairs: [(wrong: "Hanoi", right: "Haynoi"), (wrong: "Afider", right: "Affitor")]
        )
        XCTAssertTrue(system.contains("\"Hanoi\" → \"Haynoi\""))
        XCTAssertTrue(system.contains("\"Afider\" → \"Affitor\""))
        // The grounding constraint is load-bearing (ungrounded fix-up passes
        // over-correct) — its two halves must survive any future rewording pass.
        XCTAssertTrue(system.contains("only where the misrecognized form actually occurs"))
        XCTAssertTrue(system.contains("never insert these terms anywhere else"))
        XCTAssertTrue(system.hasSuffix("BASE"))
    }

    // MARK: - correctionPairs activation gate

    func testCorrectionPairsRespectTheActivationGate() {
        let dict = PersonalDictionary.shared
        var cleanup: [UUID] = []
        defer { cleanup.forEach { dict.delete(id: $0) } }

        // Manual replacement — always trusted, must appear.
        if let e = dict.addReplacement(wrong: "pairGateManualW", right: "pairGateManualR") {
            cleanup.append(e.id)
        }
        // Learned but unconfirmed (conf 1 < 2) — must NOT appear.
        if let e = dict.upsertLearnedReplacement(
            wrong: "pairGateLearnedW", right: "pairGateLearnedR", confirmations: 1
        ) {
            cleanup.append(e.id)
        }
        // Plain term — has no wrong form, must NOT appear.
        if let e = dict.addTerm("pairGateTermR") {
            cleanup.append(e.id)
        }

        let pairs = dict.correctionPairs(max: 100)
        XCTAssertTrue(pairs.contains { $0.wrong == "pairGateManualW" && $0.right == "pairGateManualR" },
                      "manual replacement must reach the LLM pass")
        XCTAssertFalse(pairs.contains { $0.wrong == "pairGateLearnedW" },
                       "unconfirmed learned rule must not reach the LLM either — same gate as the deterministic replace")
        XCTAssertFalse(pairs.contains { $0.right == "pairGateTermR" },
                       "a bare term has no wrong form and is not a pair")
    }

    // MARK: - v2 Phase 5: trust controls

    /// Pure-filter invariant behind `deleteAllLearned`: learned entries go,
    /// manual entries survive — tested WITHOUT touching the real dictionary.
    func testRemovingLearnedKeepsManualEntries() {
        let manual = DictionaryEntry(right: "Keep", kind: .term, source: .manual)
        let learnedTerm = DictionaryEntry(right: "DropA", kind: .term, source: .learned)
        let learnedRule = DictionaryEntry(right: "DropB", wrong: "dropb", kind: .replacement,
                                          source: .learned, confirmations: 2)

        let kept = PersonalDictionary.removingLearned([manual, learnedTerm, learnedRule])
        XCTAssertEqual(kept.map(\.right), ["Keep"], "only the manual entry survives")
    }

    func testLearningSettingsDefaultsOnWhenKeyAbsent() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: LearningSettings.key)
        defer {
            // Restore whatever state the machine had (absent or an explicit bool).
            if let original {
                defaults.set(original, forKey: LearningSettings.key)
            } else {
                defaults.removeObject(forKey: LearningSettings.key)
            }
        }

        defaults.removeObject(forKey: LearningSettings.key)
        XCTAssertTrue(LearningSettings.isEnabled,
                      "absent key must read as ON — the muteMusic fresh-install bug class")
        defaults.set(false, forKey: LearningSettings.key)
        XCTAssertFalse(LearningSettings.isEnabled)
        defaults.set(true, forKey: LearningSettings.key)
        XCTAssertTrue(LearningSettings.isEnabled)
    }

    // MARK: - Invariant: wrong forms never reach the STT-side glossary

    /// The STT `prompt` is prior-text conditioning — a `wrong` form there would
    /// bias the decoder TOWARD the error. Pairs go only to the rewrite pass.
    func testWrongFormsNeverLeakIntoSTTGlossary() {
        let dict = PersonalDictionary.shared
        var cleanup: [UUID] = []
        defer { cleanup.forEach { dict.delete(id: $0) } }

        if let e = dict.addReplacement(wrong: "leakTestWrongZqx", right: "leakTestRightZqx") {
            cleanup.append(e.id)
        }

        XCTAssertFalse(dict.glossaryTerms(maxChars: 10_000).contains("leakTestWrongZqx"))
        XCTAssertTrue(dict.glossaryTerms(maxChars: 10_000).contains("leakTestRightZqx"))
        XCTAssertFalse(CustomDictionary.promptFragment.contains("leakTestWrongZqx"))
    }
}
