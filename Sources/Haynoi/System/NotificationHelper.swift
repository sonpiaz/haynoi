import UserNotifications

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by PipelineController after a successful dictation.
    /// SettingsView listens to this and refreshes the credit balance.
    static let haynoiDictationCompleted = Notification.Name("com.haynoi.dictationCompleted")
}

/// Shared notification helpers used by the pipeline and failure-recovery paths.
///
/// Pattern mirrors TextInserter.copyToClipboardWithNotification so all
/// notification construction lives in one place.
enum NotificationHelper {

    // MARK: - Failed Dictation

    /// Posts a UNUserNotification telling the user that transcription failed
    /// but the audio was saved locally and can be retried.
    ///
    /// - Parameter identifier: Stable ID for the notification.  Callers that
    ///   want to replace an earlier "failed" badge pass the same ID;
    ///   callers that want distinct entries pass a unique one.
    static func postFailedDictation(identifier: String = "haynoi-failed-dictation") {
        let content = UNMutableNotificationContent()
        content.title = "Haynoi"
        content.subtitle = "Couldn't transcribe — recording saved."
        content.body = "Click to retry the last dictation."
        content.sound = .default
        // userInfo key lets the app delegate route the click
        content.userInfo = ["action": "retryLastDictation"]

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err = err {
                NSLog("[Haynoi] Failed to post failedDictation notification: %@",
                      err.localizedDescription)
            }
        }
    }

    // MARK: - Session Expired (401 — key revoked)

    /// Posts a notification telling the user their session has expired and they
    /// must sign in again.  Tapping the notification opens Haynoi Settings.
    static func postSessionExpired() {
        let content = UNMutableNotificationContent()
        content.title = "Haynoi"
        content.subtitle = "Session expired."
        content.body = "Open Settings (⌘,) to sign in again."
        content.sound = .default
        content.userInfo = ["action": "openSettings"]

        let request = UNNotificationRequest(
            identifier: "haynoi-session-expired",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err = err {
                NSLog("[Haynoi] Failed to post sessionExpired notification: %@",
                      err.localizedDescription)
            }
        }
    }

    // MARK: - Microphone Access Revoked

    /// Posts a notification deep-linking into System Settings → Microphone so
    /// the user can re-grant access without hunting through menus.
    static func postMicPermissionRevoked() {
        let content = UNMutableNotificationContent()
        content.title = "Haynoi"
        content.subtitle = "Microphone access was revoked."
        content.body = "Click to open System Settings and re-grant access."
        content.sound = .default
        content.userInfo = ["action": "openMicSettings"]

        let request = UNNotificationRequest(
            identifier: "haynoi-mic-revoked",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err = err {
                NSLog("[Haynoi] Failed to post micRevoked notification: %@",
                      err.localizedDescription)
            }
        }
    }
}
