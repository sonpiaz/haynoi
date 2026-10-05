import XCTest

/// W37-1847: Pro is not on sale (decided 05/10). The Plans & Billing tab keeps
/// the Pro card as "Coming soon" and must not show a price or start checkout.
final class BillingTabNotSellingTests: XCTestCase {
    func testBillingTabShowsProAsComingSoonWithoutCheckout() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Haynoi/Settings/SettingsView.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "private struct BillingTab: View {"))
        let rest = src[start.upperBound...]
        let body = String(rest[..<(rest.range(of: "\nprivate struct ")?.lowerBound ?? rest.endIndex)])
        XCTAssertFalse(body.contains("startCheckout"), "the tab must not open Stripe checkout")
        XCTAssertFalse(body.contains("Upgrade to Pro"))
        XCTAssertNil(body.range(of: #"\$[1-9][0-9]*\.[0-9]{2}"#, options: .regularExpression), "no Pro price")
        XCTAssertTrue(body.contains("Text(\"Coming soon\")"))
    }
}
