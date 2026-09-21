import Foundation

/// How dictations actually end up in the target app, counted per app.
///
/// "About one in ten does not paste" is not a number anyone can act on, and the
/// app had no way to tell a paste that landed from one that vanished. This keeps
/// a counter per outcome per app id — never a word of what was said, never a timestamp of
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
        /// No ⌘V was posted at all: wrong app up front, modifiers held, or no
        /// accessibility permission.
        case notAttempted
        /// ⌘V was not taken and the AX write reported success without the field
        /// changing — so the sentence may or may not be in the box. Counted
        /// apart, because calling it a failure would overstate what we saw.
        case axUnconfirmed
    }

    /// Where the counters live. Same isolation as the dictionary: a debug build
    /// writes to its own folder, and a test run writes to a temp directory —
    /// without it, an ordinary ⌘R run would mix its numbers into the ones these
    /// counters exist to measure, and the guarantee written after the dictionary
    /// was wiped on 2026-09-17 would have a hole in it.
    static func defaultFileURL(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.sonpiaz.haynoi",
        isRunningTests: Bool = RunMode.isHostingXCTestBundle()
    ) -> URL {
        let fm = FileManager.default
        var base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        if isRunningTests {
            base = fm.temporaryDirectory
                .appendingPathComponent("HaynoiTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let dir = base.appendingPathComponent(
            PersonalDictionary.supportFolderName(bundleIdentifier: bundleIdentifier, isRunningTests: isRunningTests),
            isDirectory: true
        )
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("paste-stats.json")
    }

    /// Overridable so a test can point at a file of its own.
    static var storeURL: URL = defaultFileURL()

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
