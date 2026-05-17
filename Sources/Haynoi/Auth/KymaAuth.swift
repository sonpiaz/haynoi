import AppKit
import AuthenticationServices
import Foundation

/// OAuth 2.0 Authorization Code Flow with PKCE for Haynoi → Kyma.
///
/// Flow (RFC 6749 + RFC 7636):
///   1. signIn() generates PKCE verifier + challenge
///   2. ASWebAuthenticationSession opens kymaapi.com/v1/auth/authorize
///      with challenge + redirect_uri=haynoi://callback
///   3. User signs in (if needed) and clicks Allow
///   4. Kyma redirects to haynoi://callback?code=...&state=...
///   5. ASWebAuth captures callback, returns to app, window auto-closes
///   6. exchangeCodeForToken() POSTs code + verifier to /v1/auth/token
///   7. Kyma verifies SHA256(verifier) == stored challenge, returns api_key
///   8. api_key stored in macOS Keychain
final class KymaAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    @MainActor static let shared = KymaAuth()

    static let baseURL = "https://kymaapi.com"
    static let clientID = "haynoi"
    static let redirectURI = "haynoi://callback"
    static let apiKeyKeychainKey = "haynoi.kyma.api_key"
    static let userEmailKeychainKey = "haynoi.kyma.user_email"

    private var currentSession: ASWebAuthenticationSession?

    enum AuthError: LocalizedError {
        case cancelled
        case stateMismatch
        case missingCode
        case network
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in cancelled"
            case .stateMismatch: return "Security check failed — please try again"
            case .missingCode: return "No authorization code received"
            case .network: return "Network error — check connection"
            case .server(let code, let msg): return "Server error \(code): \(msg)"
            }
        }
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String?
        let user_id: String
        let email: String
        let balance: Double?
    }

    // MARK: - Public API

    /// Initiates the OAuth flow. Returns on success or throws AuthError.
    /// Caller should refresh UI from currentUserEmail after success.
    func signIn() async throws -> TokenResponse {
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.generateChallenge(from: verifier)
        let state = PKCE.generateVerifier()  // reuse verifier helper for random state

        var components = URLComponents(string: "\(Self.baseURL)/v1/auth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "openid email"),
        ]
        let authURL = components.url!

        let callbackURL = try await openAuthSession(url: authURL)

        guard let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
            throw AuthError.missingCode
        }
        let returnedState = queryItems.first(where: { $0.name == "state" })?.value
        let code = queryItems.first(where: { $0.name == "code" })?.value

        guard returnedState == state else { throw AuthError.stateMismatch }
        guard let code, !code.isEmpty else { throw AuthError.missingCode }

        let token = try await exchangeCodeForToken(code: code, verifier: verifier)

        try KeychainStorage.save(token.access_token, for: Self.apiKeyKeychainKey)
        try KeychainStorage.save(token.email, for: Self.userEmailKeychainKey)
        return token
    }

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

    // MARK: - Internal

    private func openAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "haynoi"
            ) { callbackURL, error in
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AuthError.missingCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false  // share Safari cookies → 1-time sign in
            self.currentSession = session
            session.start()
        }
    }

    private func exchangeCodeForToken(code: String, verifier: String) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/v1/auth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
        ]
        req.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AuthError.network }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.server(http.statusCode, msg)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}
