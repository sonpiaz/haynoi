import Foundation

/// How dictations actually end up in the target app, counted per app.
///
/// "About one in ten does not paste" is not a number anyone can act on, and the
/// app had no way to tell a paste that landed from one that vanished. This keeps
/// four counters per app id — never a word of what was said, never a timestamp of
/// it — so the next question about auto-paste can be answered with a measurement.
enum PasteStats {

    enum Outcome: String, CaseIterable {
        /// The target read the clipboard after ⌘V.
        case taken
        /// ⌘V was not taken, but the AX write landed and the field changed.
        case takenViaAX
        /// Nobody read it; the sentence is on the clipboard for a manual ⌘V.
        case keptForManualPaste
        /// Nobody read it, and the user's own copy was kept instead.
        case keptUserCopy
        /// The paste was never attempted: wrong app up front, modifiers held,
        /// no accessibility permission.
        case notAttempted
    }

    /// Overridable so tests never touch the real file.
    static var storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Haynoi", isDirectory: true)
        return dir.appendingPathComponent("paste-stats.json")
    }()

    private static let queue = DispatchQueue(label: "com.sonpiaz.haynoi.paste-stats")

    static func record(_ outcome: Outcome, app: String?) {
        let key = app ?? "unknown"
        queue.async {
            var counts = load()
            counts[key, default: [:]][outcome.rawValue, default: 0] += 1
            save(counts)
        }
    }

    /// [app id: [outcome: count]]
    static func load() -> [String: [String: Int]] {
        guard let data = try? Data(contentsOf: storeURL),
              let counts = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else { return [:] }
        return counts
    }

    private static func save(_ counts: [String: [String: Int]]) {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Waits for pending writes — tests only.
    static func flush() { queue.sync {} }
}
