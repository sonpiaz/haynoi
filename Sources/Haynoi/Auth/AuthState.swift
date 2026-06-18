import Foundation

/// Shared observable auth state — single source of truth for signed-in email
/// and whether the current API key has been revoked server-side (401).
///
/// SettingsView observes this instead of seeding @State once at init, so every
/// surface (Settings, menu bar, overlay) stays in sync after a sign-in or
/// sign-out, including the 401-invalidation path.
@MainActor
final class AuthState: ObservableObject {
    static let shared = AuthState()

    /// The email of the signed-in user, or nil when signed out.
    @Published var signedInEmail: String?

    /// True when the server returned 401 (key revoked).  The key has already
    /// been deleted from the keychain by the time this is set; the user must
    /// sign in again to get a new key.
    @Published var keyInvalid: Bool = false

    private init() {
        signedInEmail = HaynoiAuth.currentUserEmail
    }

    /// Call after a successful sign-in to refresh email and clear invalid flag.
    func didSignIn(email: String) {
        signedInEmail = email
        keyInvalid = false
    }

    /// Call on sign-out (user-initiated or 401-triggered).
    func didSignOut() {
        signedInEmail = nil
        keyInvalid = false
    }

    /// Call when the server returns 401.  Clears keychain and marks key invalid.
    /// Idempotent: concurrent transcribe + rewrite 401s must not double-fire.
    func handleKeyRevoked() {
        guard !keyInvalid else { return }
        HaynoiAuth.signOut()
        signedInEmail = nil
        keyInvalid = true
        NSLog("[Haynoi] API key revoked by server (401) — user must re-authenticate")
    }
}
