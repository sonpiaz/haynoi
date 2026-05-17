import Foundation

/// Kyma device code flow for Mac OAuth — mirrors `gh auth login` / CodexBar.
///
/// Flow:
/// 1. `startDeviceFlow()` → returns user-facing code (KYMA-XXXX) + verification URL
/// 2. User opens URL in browser, signs in to Kyma, enters code
/// 3. `pollForApproval()` → blocks until approved or expired, returns kyma-xxx API key
/// 4. API key stored in Keychain as "haynoi.kyma.api_key"
enum KymaAuth {
    static let baseURL = "https://kymaapi.com"
    static let apiKeyKeychainKey = "haynoi.kyma.api_key"
    static let userEmailKeychainKey = "haynoi.kyma.user_email"

    struct DeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_url: String
        let interval: Int
        let expires_in: Int
    }

    struct TokenResponse: Decodable {
        let api_key: String
        let user_id: String
        let email: String
        let balance: Double?
    }

    enum AuthError: LocalizedError {
        case network
        case expired
        case denied
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .network: return "Network error — check connection"
            case .expired: return "Code expired — please try again"
            case .denied: return "Access denied"
            case .server(let code, let msg): return "Server error \(code): \(msg)"
            }
        }
    }

    // MARK: - Step 1: Request device code

    static func startDeviceFlow() async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: "\(baseURL)/v1/auth/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_name": "Haynoi"])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AuthError.network }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.server(http.statusCode, msg)
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    // MARK: - Step 2: Poll for approval

    /// Polls every `interval` seconds until approved or expires.
    /// Throws `.expired` after `expires_in` seconds.
    static func pollForApproval(
        deviceCode: String,
        interval: Int,
        expiresIn: Int
    ) async throws -> TokenResponse {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var req = URLRequest(url: URL(string: "\(baseURL)/v1/auth/device/token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["device_code": deviceCode])

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { continue }

            switch http.statusCode {
            case 200:
                let token = try JSONDecoder().decode(TokenResponse.self, from: data)
                try KeychainStorage.save(token.api_key, for: apiKeyKeychainKey)
                try KeychainStorage.save(token.email, for: userEmailKeychainKey)
                return token
            case 428:
                continue  // still pending — keep polling
            case 400:
                throw AuthError.expired
            default:
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw AuthError.server(http.statusCode, msg)
            }
        }
        throw AuthError.expired
    }

    // MARK: - Helpers

    static var currentApiKey: String? {
        KeychainStorage.load(apiKeyKeychainKey)
    }

    static var currentUserEmail: String? {
        KeychainStorage.load(userEmailKeychainKey)
    }

    static var isSignedIn: Bool {
        currentApiKey != nil
    }

    static func signOut() {
        KeychainStorage.delete(apiKeyKeychainKey)
        KeychainStorage.delete(userEmailKeychainKey)
    }
}
