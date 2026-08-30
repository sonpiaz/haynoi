import XCTest
@testable import Haynoi

/// v2 Phase 3 (Signal E): the logprob-gated correction pass. The gate must be
/// closed unless ALL of: no rewrite mode, a low-confidence token, and grounding
/// context — an ungrounded LLM fix-up pass over-corrects, and rewrite modes
/// already carry the glossary + pairs.
final class CorrectionPassTests: XCTestCase {

    func testLowConfidenceDetector() {
        XCTAssertFalse(STTProvider.hasLowConfidenceToken([]), "no data = no doubt signal")
        XCTAssertFalse(STTProvider.hasLowConfidenceToken([-0.01, -0.2, -0.9]),
                       "all tokens above the floor")
        XCTAssertTrue(STTProvider.hasLowConfidenceToken([-0.01, -2.4, -0.2]),
                      "one doubtful token opens the gate")
        XCTAssertFalse(STTProvider.hasLowConfidenceToken([STTProvider.lowConfidenceLogprob]),
                       "the floor itself is not below the floor")
    }

    func testGateClosedWithoutLogprobs() {
        XCTAssertFalse(STTProvider.shouldRunCorrectionPass(
            needsRewrite: false, logprobs: nil, hasGrounding: true),
            "gateway not shipping logprobs yet → dormant")
    }

    func testGateClosedForRewriteModes() {
        XCTAssertFalse(STTProvider.shouldRunCorrectionPass(
            needsRewrite: true, logprobs: [-3.0], hasGrounding: true),
            "rewrite modes already carry glossary + pairs — never pay twice")
    }

    func testGateClosedWithoutGrounding() {
        XCTAssertFalse(STTProvider.shouldRunCorrectionPass(
            needsRewrite: false, logprobs: [-3.0], hasGrounding: false),
            "ungrounded LLM correction over-corrects — no grounding, no call")
    }

    func testGateClosedWhenConfident() {
        XCTAssertFalse(STTProvider.shouldRunCorrectionPass(
            needsRewrite: false, logprobs: [-0.1, -0.3], hasGrounding: true))
    }

    func testGateOpensOnlyWhenAllConditionsHold() {
        XCTAssertTrue(STTProvider.shouldRunCorrectionPass(
            needsRewrite: false, logprobs: [-0.1, -2.2], hasGrounding: true))
    }

    func testCorrectionPromptComposesUnderGrounding() {
        let system = STTProvider.rewriteSystemPrompt(
            base: STTProvider.correctionPassPrompt,
            glossary: ["Haynoi"],
            pairs: [(wrong: "Hanoi", right: "Haynoi")]
        )
        XCTAssertTrue(system.hasSuffix(STTProvider.correctionPassPrompt),
                      "grounding sections must sit ABOVE the correction instruction")
        XCTAssertTrue(system.contains("\"Hanoi\" → \"Haynoi\""))
        XCTAssertTrue(STTProvider.correctionPassPrompt.contains("Change nothing else"),
                      "the no-rephrasing constraint is load-bearing")
    }
}
