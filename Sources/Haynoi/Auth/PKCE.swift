import CryptoKit
import Foundation

/// PKCE (Proof Key for Code Exchange) helpers for OAuth 2.0 Authorization
/// Code Flow. RFC 7636.
///
/// Flow:
///   1. Mac generates verifier (random) + challenge (SHA256(verifier)).
///   2. Mac sends challenge to /authorize. Server stores it.
///   3. Server returns auth code. Mac sends code + verifier to /token.
///   4. Server checks SHA256(verifier) == stored challenge → issues token.
///
/// Prevents auth code interception attacks on public clients (Mac apps
/// can't keep client_secret confidential, so PKCE replaces it).
enum PKCE {
    /// 32 random bytes → base64url string. RFC 7636 requires 43-128 chars.
    static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandomCopyBytes failed (extremely rare — e.g. entropy source not ready).
            // Fall back to SystemRandomNumberGenerator so the verifier is never all-zeros.
            NSLog("[Haynoi] SecRandomCopyBytes failed (status %d), falling back to SystemRandomNumberGenerator", status)
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return base64URLEncode(Data(bytes))
    }

    /// SHA256(verifier) → base64url. The "S256" challenge method.
    static func generateChallenge(from verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hashed))
    }

    /// base64url = base64 with -_ instead of +/ and no padding.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
