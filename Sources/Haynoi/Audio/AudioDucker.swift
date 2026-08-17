import AppKit
import Foundation

/// Turns the system output down while you dictate, and — the hard part — always
/// puts it back.
///
/// Ducking is the answer for audio that must not be paused: a Zoom call, a live
/// stream, a screen recording. Pausing those is destructive; lowering them for
/// three seconds is not.
///
/// The failure mode this class exists to avoid is a user left at volume 0 with
/// no idea why. Every path is defended:
///
///  * **Verified writes** — the HAL is asked what the volume actually is after
///    every write. USB DACs that ack-but-ignore are detected, and we then
///    remember that we never really ducked, so restore is not attempted.
///  * **Crash breadcrumb** — the original volume is written to UserDefaults
///    *before* the device is touched. If Haynoi dies mid-dictation, the next
///    launch restores it (`restoreStaleDuck`).
///  * **User wins** — if the volume changed from what we set (the user reached
///    for their keyboard mid-dictation), we drop our claim instead of
///    overwriting their choice.
///  * **Device-pinned** — restore targets the device UID we ducked, not
///    whatever happens to be default when dictation ends.
///
/// Not tied to a queue: an internal lock makes it safe from anywhere.
enum AudioDucker {

    /// Volume floor below which ducking buys nothing and only risks a stuck
    /// restore. 5% is already barely audible.
    private static let minimumVolumeToDuck: Float = 0.05

    /// How far the volume may drift from what we set before we conclude the
    /// user (or another app) moved it and back off.
    private static let ownershipTolerance: Float = 0.05

    private static let breadcrumbKey = "audioDuck.pending"

    private struct Claim {
        let uid: String
        let original: Float
        let applied: Float
    }

    private static let lock = NSLock()
    private static var claim: Claim?

    /// Fraction of the original volume to leave audible, 0…1.
    /// Default 0.2 — quiet enough to stop competing with your voice, loud enough
    /// that you still notice someone saying your name on the call.
    static var duckFraction: Float {
        let stored = UserDefaults.standard.object(forKey: "duckFraction") as? Double
        return Float(min(max(stored ?? 0.2, 0), 0.9))
    }

    static var isDucked: Bool {
        lock.lock(); defer { lock.unlock() }
        return claim != nil
    }

    // MARK: - Duck

    @discardableResult
    static func duck() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard claim == nil else { return true } // already ducked — idempotent

        guard let device = SystemAudio.defaultOutputDevice,
              let uid = SystemAudio.uid(of: device),
              let original = SystemAudio.outputVolume(of: device),
              original >= minimumVolumeToDuck
        else { return false }

        let target = original * duckFraction

        // Breadcrumb first: if we die between here and the restore, the next
        // launch still knows what the volume used to be.
        UserDefaults.standard.set(
            ["uid": uid, "original": Double(original), "applied": Double(target), "at": Date().timeIntervalSince1970],
            forKey: breadcrumbKey
        )

        guard SystemAudio.setOutputVolume(target, on: device) else {
            // Device lied about the write. Claim nothing, so we never "restore"
            // a volume we did not change.
            UserDefaults.standard.removeObject(forKey: breadcrumbKey)
            NSLog("[Haynoi] Duck rejected by output device — leaving volume alone")
            return false
        }

        claim = Claim(uid: uid, original: original, applied: target)
        return true
    }

    // MARK: - Restore

    static func restore() {
        lock.lock(); defer { lock.unlock() }
        guard let claim else { return }
        self.claim = nil
        UserDefaults.standard.removeObject(forKey: breadcrumbKey)
        apply(claim)
    }

    /// Called once at launch: repairs a volume left low by a crash, a force
    /// quit, or a logout in the middle of a dictation.
    static func restoreStaleDuck() {
        lock.lock(); defer { lock.unlock() }
        guard claim == nil,
              let stored = UserDefaults.standard.dictionary(forKey: breadcrumbKey),
              let uid = stored["uid"] as? String,
              let original = stored["original"] as? Double,
              let applied = stored["applied"] as? Double
        else { return }

        UserDefaults.standard.removeObject(forKey: breadcrumbKey)

        // A breadcrumb older than a day is not worth acting on: whatever the
        // volume is now, it is what the user has been living with.
        if let at = stored["at"] as? TimeInterval, Date().timeIntervalSince1970 - at > 86_400 { return }

        NSLog("[Haynoi] Restoring output volume left ducked by a previous session")
        apply(Claim(uid: uid, original: Float(original), applied: Float(applied)))
    }

    /// Restores `claim.original` on the exact device that was ducked, unless the
    /// volume has since moved away from what we set — in which case the user
    /// owns it now and we keep our hands off.
    private static func apply(_ claim: Claim) {
        guard let device = SystemAudio.device(withUID: claim.uid) else { return }
        if let current = SystemAudio.outputVolume(of: device),
           abs(current - claim.applied) > ownershipTolerance {
            NSLog("[Haynoi] Output volume changed during dictation — keeping the user's level")
            return
        }
        if !SystemAudio.setOutputVolume(claim.original, on: device) {
            // Retry once: transient HAL failures around a device switch are real,
            // and a silent Mac is the worst outcome this feature can produce.
            _ = SystemAudio.setOutputVolume(claim.original, on: device)
        }
    }
}
