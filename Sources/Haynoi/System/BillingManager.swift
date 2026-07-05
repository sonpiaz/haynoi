import AppKit
import Foundation

// MARK: - BillingManager
//
// Stripe subscription state + checkout flow via haynoi-server /v1/billing/*.
// Checkout happens in the browser (Stripe Checkout); the server webhook flips
// the tier in D1, so after opening the URL we poll /v1/billing/subscription
// until the upgrade lands (or the user gives up and the poll times out).

@MainActor
final class BillingManager: ObservableObject {
    static let shared = BillingManager()

    struct Subscription: Decodable {
        let tier: String
        let cycle: String
        let status: String
        let currentPeriodEnd: Double  // epoch ms
        let cancelAtPeriodEnd: Bool
    }

    @Published private(set) var tier: String = "free"
    @Published private(set) var subscription: Subscription?
    /// True from "Upgrade" click until the webhook lands or polling gives up.
    @Published private(set) var awaitingCheckout = false
    @Published var lastError: String?

    var isPro: Bool { tier == "pro" || tier == "max" }

    private init() {}

    private struct SubscriptionResponse: Decodable {
        let ok: Bool
        let tier: String
        let subscription: Subscription?
    }

    private struct CheckoutResponse: Decodable {
        let ok: Bool
        let url: String
    }

    private struct APIError: Decodable {
        struct Body: Decodable { let code: String; let message: String }
        let error: Body
    }

    func refresh() async {
        guard let token = HaynoiAuth.currentToken else { return }
        do {
            let resp: SubscriptionResponse = try await request(
                "GET", "/v1/billing/subscription", token: token)
            tier = resp.tier
            subscription = resp.subscription
        } catch {
            NSLog("[Haynoi] BillingManager.refresh: %@", error.localizedDescription)
        }
    }

    /// Create a Stripe Checkout session, open it in the browser, then poll
    /// for the webhook-driven tier flip (every 3s, up to 10 minutes).
    func startCheckout(cycle: String) async {
        guard let token = HaynoiAuth.currentToken else { return }
        lastError = nil
        do {
            let resp: CheckoutResponse = try await request(
                "POST", "/v1/billing/checkout", token: token,
                body: ["plan": "pro", "cycle": cycle])
            guard let url = URL(string: resp.url) else { return }
            NSWorkspace.shared.open(url)
            awaitingCheckout = true
            for _ in 0..<200 where awaitingCheckout {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                await refresh()
                if isPro {
                    awaitingCheckout = false
                    BalanceManager.shared.refresh()
                    Analytics.capture("upgrade_completed", ["cycle": cycle])
                }
            }
            awaitingCheckout = false
        } catch {
            awaitingCheckout = false
            lastError = error.localizedDescription
            NSLog("[Haynoi] BillingManager.startCheckout: %@", error.localizedDescription)
        }
    }

    /// Open the Stripe Customer Portal (manage plan, payment method, invoices).
    func openPortal() async {
        guard let token = HaynoiAuth.currentToken else { return }
        do {
            let resp: CheckoutResponse = try await request(
                "POST", "/v1/billing/portal", token: token, body: [:])
            if let url = URL(string: resp.url) { NSWorkspace.shared.open(url) }
        } catch {
            lastError = error.localizedDescription
            NSLog("[Haynoi] BillingManager.openPortal: %@", error.localizedDescription)
        }
    }

    // MARK: - HTTP

    private func request<T: Decodable>(
        _ method: String, _ path: String, token: String,
        body: [String: String]? = nil
    ) async throws -> T {
        var req = URLRequest(url: URL(string: "\(HaynoiAuth.baseURL)\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            if let api = try? JSONDecoder().decode(APIError.self, from: data) {
                throw NSError(
                    domain: "HaynoiBilling", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: api.error.message])
            }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
