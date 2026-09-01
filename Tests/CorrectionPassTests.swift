import XCTest
@testable import Haynoi

/// v2 Phase 3 (Signal E): the logprob-gated correction pass. The gate must be
/// closed unless ALL of: no rewrite mode, a low-confidence token, and grounding
/// context — an ungrounded LLM fix-up pass over-corrects, and rewrite modes
/// already carry the glossary + pairs.
final class CorrectionPassTests: XCTestCase {

    func testLowConfidenceDetector() {
        let floor = STTProvider.lowConfidenceLogprob
        XCTAssertFalse(STTProvider.hasLowConfidenceToken([]), "no data = no doubt signal")
        XCTAssertFalse(STTProvider.hasLowConfidenceToken([-0.001, floor + 0.05]),
                       "all tokens above the floor")
        XCTAssertTrue(STTProvider.hasLowConfidenceToken([-0.001, floor - 0.05]),
                      "one doubtful token opens the gate")
        XCTAssertFalse(STTProvider.hasLowConfidenceToken([floor]),
                       "the floor itself is not below the floor")
    }

    /// Regression pin against the LIVE gateway measurement (2026-08-29) that
    /// set the threshold: misrecognized name tokens measured -0.25…-1.11 and
    /// must open the gate; correct tokens measured ≈-0.0001…-0.006 and must
    /// not. "Hanoi" (confidently wrong at -0.006) is intentionally invisible
    /// to this signal — the deterministic replace owns that class.
    func testThresholdCatchesMeasuredErrorTokens() {
        for measured in [-0.9093, -0.4039, -0.3689, -1.1107] {
            XCTAssertTrue(STTProvider.hasLowConfidenceToken([measured]),
                          "measured error token \(measured) must open the gate")
        }
        XCTAssertFalse(STTProvider.hasLowConfidenceToken([-0.0002, -0.0061, -0.0006]),
                       "confident tokens (incl. the Hanoi-class error) stay closed")
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
            needsRewrite: false,
            logprobs: [-0.001, STTProvider.lowConfidenceLogprob + 0.05],
            hasGrounding: true))
    }

    func testGateOpensOnlyWhenAllConditionsHold() {
        XCTAssertTrue(STTProvider.shouldRunCorrectionPass(
            needsRewrite: false, logprobs: [-0.1, -2.2], hasGrounding: true))
    }

    // MARK: - 402 attribution: whose fault is a 402?

    func testQuotaExhaustedBodyIsRecognized() {
        let ours = #"{"error":{"code":"quota_exhausted","message":"Weekly words limit reached."}}"#
        XCTAssertTrue(STTProvider.isQuotaExhausted(Data(ours.utf8)))
    }

    func testUpstreamShapedBodiesAreNotBlamedOnTheUser() {
        for body in [
            #"{"error":{"message":"Insufficient balance","type":"billing_error"}}"#,  // upstream 402, no code
            #"{"error":{"code":"upstream_unavailable","message":"..."}}"#,
            #"not json at all"#,
            #"{}"#,
        ] {
            XCTAssertFalse(STTProvider.isQuotaExhausted(Data(body.utf8)),
                           "must never read as the user's quota: \(body)")
        }
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
