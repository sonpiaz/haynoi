import AppKit
import Foundation

/// Authentication against the haynoi-server backend (api.haynoi.com).
///
/// Sign-in is Google-only, returning a 52-char session token stored in the
/// macOS Keychain:
///   • Google — the DEFAULT browser opens /auth/google; the server handles
///     the OAuth dance and 302-redirects to haynoi://auth?session_token=…
///     (no PKCE on the client — the server owns the Google credentials).
///     AppDelegate feeds the haynoi:// URL back via handleCallback(_:).
///
/// Default browser (not ASWebAuthenticationSession, which is Safari-backed)
/// so the OAuth round-trip runs where the user actually browses — the server
/// reads the Affitor first-party attribution cookies (.haynoi.com) at the
/// callback, which only exist in the browser that clicked the partner link.
///
/// The token is sent as `Authorization: Bearer <token>` on every proxied
/// dictation / rewrite / usage call (see STTProvider, BalanceManager).
@MainActor
final class HaynoiAuth: NSObject {
    static let shared = HaynoiAuth()

    nonisolated static let baseURL = "https://api.haynoi.com"
    nonisolated static let redirectURI = "haynoi://auth"
    nonisolated static let tokenKeychainKey = "haynoi.access_token"
    nonisolated static let userEmailKeychainKey = "haynoi.user_email"
    nonisolated static let userNameKeychainKey = "haynoi.user_name"
    nonisolated static let userIdKeychainKey = "haynoi.user_id"

    /// The in-flight sign-in waiting for the haynoi:// callback.
    private var pendingCallback: CheckedContinuation<URL, Error>?
    /// Monotonic attempt counter so a stale timeout can't kill a newer attempt.
    private var attemptId = 0

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
        // Persist the ULID user_id so analytics' distinct_id matches the server's
        // and the website's — web + app + server all unify on the same identity.
        try? KeychainStorage.save(user.id, for: Self.userIdKeychainKey)
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

    /// The signed-in user's ULID (users.id), when known. Used as the analytics
    /// distinct_id so app events unify with the server + website on one identity.
    nonisolated static var currentUserId: String? {
        KeychainStorage.load(userIdKeychainKey)
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
        KeychainStorage.delete(userIdKeychainKey)
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

    /// AppDelegate routes haynoi:// URLs here (kAEGetURL / application(_:open:)).
    func handleCallback(_ url: URL) {
        guard url.scheme == "haynoi" else { return }
        pendingCallback?.resume(returning: url)
        pendingCallback = nil
    }

    private func openAuthSession(url: URL) async throws -> URL {
        // A new attempt supersedes any prior one still waiting.
        pendingCallback?.resume(throwing: AuthError.cancelled)
        pendingCallback = nil
        attemptId += 1
        let id = attemptId

        return try await withCheckedThrowingContinuation { continuation in
            pendingCallback = continuation
            NSWorkspace.shared.open(url)

            // The browser tab can simply be closed — nothing signals us. Time
            // the attempt out so the continuation never leaks.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard let self, self.attemptId == id, self.pendingCallback != nil else { return }
                self.pendingCallback?.resume(throwing: AuthError.cancelled)
                self.pendingCallback = nil
            }
        }
    }
}
