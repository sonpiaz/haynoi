import Foundation
import PostHog

/// Metadata-only product analytics for Haynoi.
///
/// PRIVACY INVARIANT (Haynoi is privacy-positioned — "your corrections never
/// leave your Mac"): NEVER pass transcript text, dictated content, or dictionary
/// term strings (the wrong/right words) to `capture`. The only strings ever sent
/// are the distinct_id (the ULID user_id) and a target-app **bundle ID**
/// (e.g. "com.tinyspeck.slackmacgap" — an app identifier, not content).
/// Everything else is an integer count or a closed-set enum.
///
/// Gated by the "shareUsageData" opt-out (default ON). When OFF the SDK is never
/// initialized and every entry point early-returns; `setEnabled(false)` also
/// calls `optOut()` so nothing is queued or sent.
@MainActor
enum Analytics {
    private static let key  = "phc_mKoPQ7nM2SFCam2vDQSuMBH3hw3wYKZdkdCa2YugJ8pw"
    private static let host = "https://us.i.posthog.com"
    static let optInDefaultsKey = "shareUsageData"   // Bool, default true

    /// Default true — registered in AppDelegate's UserDefaults.register(defaults:).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: optInDefaultsKey) as? Bool ?? true
    }

    private static var started = false

    /// Call once at launch. No-op (and stays uninitialized) when opted out.
    static func start() {
        guard isEnabled, !started else { return }
        let config = PostHogConfig(projectToken: key, host: host)
        config.captureApplicationLifecycleEvents = false  // we emit app_launched ourselves
        config.captureScreenViews = false                  // no autocapture
        // Session replay is iOS-only in posthog-ios and unavailable on macOS —
        // it can never run here, which satisfies the HARD "no replay" rule.
        PostHogSDK.shared.setup(config)
        started = true
        // Re-bind identity if already signed in (relaunch path).
        if let uid = HaynoiAuth.currentUserId { PostHogSDK.shared.identify(uid) }
    }

    static func identify(_ userId: String) {
        guard isEnabled else { return }
        if !started { start() }
        PostHogSDK.shared.identify(userId)
    }

    static func reset() {
        guard started else { return }
        PostHogSDK.shared.reset()
    }

    /// Capture a metadata-only event. `props` MUST contain only counts, enums,
    /// or bundle IDs — never transcript text or dictionary term strings.
    static func capture(_ event: String, _ props: [String: Any] = [:]) {
        guard isEnabled, started else { return }
        PostHogSDK.shared.capture(event, properties: props)
    }

    /// Wired from the Settings opt-out toggle. ON → start+identify; OFF →
    /// reset + optOut (hard stop; nothing queued or sent).
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: optInDefaultsKey)
        if on {
            start()
            if let uid = HaynoiAuth.currentUserId { identify(uid) }
        } else {
            reset()
            PostHogSDK.shared.optOut()
            started = false
        }
    }
}
