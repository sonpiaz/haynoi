import Foundation

// MARK: - BalanceManager
//
// Single shared observable for the Kyma credit balance.
// Replaces three independent @State creditBalance / refreshBalance() copies
// that previously lived in MenuBarContent, MainView, and AccountTab.
// All three views now @ObservedObject from BalanceManager.shared so only
// one in-flight request runs at a time regardless of which view appears first.

@MainActor
final class BalanceManager: ObservableObject {
    static let shared = BalanceManager()

    @Published private(set) var balance: Double?

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

    func refresh() {
        guard let apiKey = KymaAuth.currentApiKey else { return }
        guard !isFetching else { return }
        isFetching = true
        Task { @MainActor in
            defer { isFetching = false }
            do {
                var req = URLRequest(url: URL(string: "https://api.kymaapi.com/v1/credits/balance")!)
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let fetched = json["balance"] as? Double else { return }
                balance = fetched
            } catch {
                NSLog("[Haynoi] BalanceManager: %@", error.localizedDescription)
            }
        }
    }
}
