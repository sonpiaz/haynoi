import Foundation

// MARK: - BalanceManager
//
// Single shared observable for the signed-in user's word quota, fetched from
// haynoi-server's GET /v1/usage. Replaces the old Kyma dollar-balance model:
// Haynoi bills by words against a tier cap, not a pay-as-you-go dollar balance.
//
//   tier           "free" | "pro" | "max"
//   wordsUsed      words consumed this period
//   wordsCap       period cap — 0 means UNLIMITED (Pro / Max)
//   wordsRemaining cap - used (server-computed)
//   exhausted      true when the free-tier cap is hit (FUP / 402)
//
// All surfaces (menu bar, main window, onboarding, settings) @ObservedObject
// from BalanceManager.shared so only one in-flight request runs at a time.

@MainActor
final class BalanceManager: ObservableObject {
    static let shared = BalanceManager()

    @Published private(set) var tier: String?
    @Published private(set) var wordsUsed: Int?
    @Published private(set) var wordsCap: Int?
    @Published private(set) var wordsRemaining: Int?
    @Published private(set) var exhausted: Bool = false

    private var isFetching = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: .haynoiDictationCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private struct UsageResponse: Decodable {
        let ok: Bool
        let tier: String
        let used: Int
        let cap: Int
        let remaining: Int
        let exhausted: Bool
        let unit_label: String?
        let resets_at: String?
    }

    func refresh() {
        guard let token = HaynoiAuth.currentToken else { return }
        guard !isFetching else { return }
        isFetching = true
        Task { @MainActor in
            defer { isFetching = false }
            do {
                var req = URLRequest(url: URL(string: "\(HaynoiAuth.baseURL)/v1/usage")!)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                tier = usage.tier
                wordsUsed = usage.used
                wordsCap = usage.cap
                wordsRemaining = usage.remaining
                exhausted = usage.exhausted
            } catch {
                NSLog("[Haynoi] BalanceManager: %@", error.localizedDescription)
            }
        }
    }
}
