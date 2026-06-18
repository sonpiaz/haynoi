import AppKit
import AuthenticationServices
import Foundation

/// Authentication against the haynoi-server backend (api.haynoi.com).
///
/// Three sign-in paths, all returning a 52-char session token stored in the
/// macOS Keychain:
///   • Google — ASWebAuthenticationSession opens /auth/google; the server
///     handles the OAuth dance and 302-redirects to haynoi://auth?session_token=…
///     (no PKCE on the client — the server owns the Google credentials).
///   • Register — POST /auth/register {email, password, displayName?}.
///   • Login — POST /auth/login {email, password}.
///
/// The token is sent as `Authorization: Bearer <token>` on every proxied
/// dictation / rewrite / usage call (see STTProvider, BalanceManager).
@MainActor
final class HaynoiAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = HaynoiAuth()

    nonisolated static let baseURL = "https://api.haynoi.com"
    nonisolated static let redirectURI = "haynoi://auth"
    nonisolated static let tokenKeychainKey = "haynoi.access_token"
    nonisolated static let userEmailKeychainKey = "haynoi.user_email"

    private var currentSession: ASWebAuthenticationSession?

    // MARK: - Models

    /// Mirrors the `user` object in every auth success response.
    struct User: Decodable {
        let id: String
        let email: String
        let displayName: String?
        let avatarUrl: String?
        let tier: String
    }

    /// Success envelope for /auth/register and /auth/login.
    private struct AuthSuccess: Decodable {
        let ok: Bool
        let session_token: String
        let user: User
    }

    /// Envelope for GET /auth/me.
    private struct MeResponse: Decodable {
        let ok: Bool
        let signed_in: Bool
        let user: User?
    }

    /// Error envelope: {"error":{"code":"...","message":"..."}}.
    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let code: String; let message: String }
        let error: Body
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case cancelled
        case network
        case server(String)
        case invalidEmail
        case weakPassword
        case emailTaken
        case invalidCredentials
        case missingToken

        /// Maps a server error code to the matching friendly case.
        static func from(code: String, message: String) -> AuthError {
            switch code {
            case "invalid_email":       return .invalidEmail
            case "weak_password":       return .weakPassword
            case "email_taken":         return .emailTaken
            case "invalid_credentials": return .invalidCredentials
            default:                    return .server(message)
            }
        }

        var errorDescription: String? {
            switch self {
            case .cancelled:          return "Sign-in cancelled"
            case .network:            return "Network error — check your connection"
            case .server(let msg):    return msg.isEmpty ? "Something went wrong — try again" : msg
            case .invalidEmail:       return "Enter a valid email"
            case .weakPassword:       return "Password must be at least 8 characters"
            case .emailTaken:         return "An account with this email already exists — try signing in."
            case .invalidCredentials: return "Incorrect email or password"
            case .missingToken:       return "No session token received — try again"
            }
        }
    }

    // MARK: - Public API

    /// Opens the hosted Google flow, parses the returned session token, then
    /// fetches the user from /auth/me. Returns the signed-in User.
    func signInWithGoogle() async throws -> User {
        var components = URLComponents(string: "\(Self.baseURL)/auth/google")!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
        ]
        let authURL = components.url!

        let callbackURL = try await openAuthSession(url: authURL)

        guard let token = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "session_token" })?.value,
            !token.isEmpty else {
            throw AuthError.missingToken
        }

        try KeychainStorage.save(token, for: Self.tokenKeychainKey)

        // Pull the user (email/tier) so the UI can show it.
        let user = try await fetchMe(token: token)
        try KeychainStorage.save(user.email, for: Self.userEmailKeychainKey)
        return user
    }

    /// POST /auth/register — creates the account and signs in.
    func register(email: String, password: String, displayName: String?) async throws -> User {
        var body: [String: Any] = ["email": email, "password": password]
        if let displayName, !displayName.isEmpty { body["displayName"] = displayName }
        return try await postAuth(path: "/auth/register", body: body)
    }

    /// POST /auth/login — signs into an existing account.
    func login(email: String, password: String) async throws -> User {
        return try await postAuth(path: "/auth/login", body: ["email": email, "password": password])
    }

    // Keychain-only accessors — nonisolated so the transcription pipeline
    // (a nonisolated async context) can read the token without hopping actors.
    nonisolated static var currentToken: String? {
        KeychainStorage.load(tokenKeychainKey)
    }

    nonisolated static var currentUserEmail: String? {
        KeychainStorage.load(userEmailKeychainKey)
    }

    nonisolated static var isSignedIn: Bool {
        currentToken != nil
    }

    /// Best-effort server sign-out, then clears the local keychain regardless.
    nonisolated static func signOut() {
        if let token = currentToken {
            var req = URLRequest(url: URL(string: "\(baseURL)/auth/sign-out")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 8
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Fire-and-forget — local sign-out must succeed even if the call fails.
            URLSession.shared.dataTask(with: req).resume()
        }
        KeychainStorage.delete(tokenKeychainKey)
        KeychainStorage.delete(userEmailKeychainKey)
    }

    // MARK: - Internal

    private func postAuth(path: String, body: [String: Any]) async throws -> User {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)\(path)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AuthError.network
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.network }
        guard http.statusCode == 200 else {
            if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw AuthError.from(code: env.error.code, message: env.error.message)
            }
            throw AuthError.server("Server error (HTTP \(http.statusCode))")
        }

        let success = try JSONDecoder().decode(AuthSuccess.self, from: data)
        try KeychainStorage.save(success.session_token, for: Self.tokenKeychainKey)
        try KeychainStorage.save(success.user.email, for: Self.userEmailKeychainKey)
        return success.user
    }

    private func fetchMe(token: String) async throws -> User {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/auth/me")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AuthError.network
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.network
        }
        let me = try JSONDecoder().decode(MeResponse.self, from: data)
        guard me.signed_in, let user = me.user else { throw AuthError.missingToken }
        return user
    }

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
                    continuation.resume(throwing: AuthError.missingToken)
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

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}
