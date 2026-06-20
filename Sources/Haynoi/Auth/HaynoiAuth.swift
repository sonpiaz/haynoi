import AppKit
import AuthenticationServices
import Foundation

/// Authentication against the haynoi-server backend (api.haynoi.com).
///
/// Sign-in is Google-only, returning a 52-char session token stored in the
/// macOS Keychain:
///   • Google — ASWebAuthenticationSession opens /auth/google; the server
///     handles the OAuth dance and 302-redirects to haynoi://auth?session_token=…
///     (no PKCE on the client — the server owns the Google credentials).
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
    nonisolated static let userNameKeychainKey = "haynoi.user_name"

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

    /// Envelope for GET /auth/me.
    private struct MeResponse: Decodable {
        let ok: Bool
        let signed_in: Bool
        let user: User?
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case cancelled
        case network
        case server(String)
        case missingToken

        var errorDescription: String? {
            switch self {
            case .cancelled:          return "Sign-in cancelled"
            case .network:            return "Network error — check your connection"
            case .server(let msg):    return msg.isEmpty ? "Something went wrong — try again" : msg
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
        // Persist the Google display name for the dictionary cold-start seed,
        // and seed now — the common first-run path is launch (no name) → sign-in,
        // so the launch-time seed no-ops and this is where the name first exists.
        if let name = user.displayName, !name.isEmpty {
            try? KeychainStorage.save(name, for: Self.userNameKeychainKey)
            PersonalDictionary.shared.seedFromDisplayNameIfNeeded(displayName: name)
        }
        return user
    }

    // Keychain-only accessors — nonisolated so the transcription pipeline
    // (a nonisolated async context) can read the token without hopping actors.
    nonisolated static var currentToken: String? {
        KeychainStorage.load(tokenKeychainKey)
    }

    nonisolated static var currentUserEmail: String? {
        KeychainStorage.load(userEmailKeychainKey)
    }

    /// Google display name, when known — used to seed the personal dictionary
    /// on cold start. nil when the Google profile carried no name.
    nonisolated static var currentUserName: String? {
        KeychainStorage.load(userNameKeychainKey)
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
        KeychainStorage.delete(userNameKeychainKey)
    }

    // MARK: - Internal

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
