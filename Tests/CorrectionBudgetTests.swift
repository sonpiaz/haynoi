import XCTest
@testable import Haynoi

/// The correction pass is optional polish on text that already exists. A busy
/// or slow upstream used to hold that text for 6 s or more (429 sleeps of 2–14 s, 15 s
/// idle timeout × 3 attempts — W37-1424). With the correction session and one
/// attempt, the raw transcript comes back within the budget.
final class CorrectionBudgetTests: XCTestCase {

    private func session(_ mode: StubProtocol.Mode) -> URLSession {
        StubProtocol.mode = mode
        let config = STTProvider.correctionSessionConfiguration()
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    private func correct(_ raw: String, _ mode: StubProtocol.Mode) async -> (String, TimeInterval) {
        let start = Date()
        let text = (try? await STTProvider.rewriteWithKyma(
            token: "test", text: raw, systemPrompt: STTProvider.correctionPassPrompt,
            session: session(mode), attempts: 1
        )) ?? raw
        return (text, Date().timeIntervalSince(start))
    }

    func testBusyUpstreamDoesNotWaitOutBackoff() async {
        let (text, elapsed) = await correct("raw words", .rateLimited)
        XCTAssertEqual(text, "raw words")
        XCTAssertLessThan(elapsed, 1.0, "a 429 used to sleep 2 s before the next try")
    }

    func testHungUpstreamGivesUpAtTheBudget() async {
        let (text, elapsed) = await correct("raw words", .hang)
        XCTAssertEqual(text, "raw words")
        XCTAssertLessThan(elapsed, STTProvider.correctionBudget + 1.0)
    }

    func testAnswerWithinBudgetIsUsed() async {
        let (text, _) = await correct("raw words", .ok("corrected words"))
        XCTAssertEqual(text, "corrected words")
    }
}

private final class StubProtocol: URLProtocol {
    enum Mode { case rateLimited, hang, ok(String) }
    static var mode: Mode = .hang

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let reply: (Int, Data)
        switch Self.mode {
        case .hang:
            return
        case .rateLimited:
            reply = (429, Data())
        case .ok(let content):
            let json: [String: Any] = ["choices": [["message": ["content": content]]]]
            reply = (200, try! JSONSerialization.data(withJSONObject: json))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
}
