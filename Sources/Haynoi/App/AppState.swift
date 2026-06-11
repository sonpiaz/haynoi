import SwiftUI
import Combine

struct Transcription: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
    }

    var wordCount: Int { text.split(separator: " ").count }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var error: String?
    @Published var transcriptions: [Transcription] = []
    @Published var showOverlay = false

    // Floating orb state machine
    @Published var orbState: OrbState = .idle

    // Fix #1: hotkey tap liveness
    @Published var hotkeyActive: Bool = false

    // Fix #5: secure input blocks key events
    @Published var secureInputActive: Bool = false

    // Fix #2: whether a failed dictation WAV exists
    @Published var hasFailedDictation: Bool = false

    // Fix #4: one-shot transient status (e.g. "Max dictation length reached")
    @Published var status: String?

    // Auto-clear timer for transient status
    private var statusClearTimer: AnyCancellable?
    private var errorClearTimer: AnyCancellable?

    // History persistence — JSON file in Application Support
    private static let historyFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Haynoi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private static let maxHistoryEntries = 500

    // Debounced save publisher
    private let saveSubject = PassthroughSubject<Void, Never>()
    private var saveCancellable: AnyCancellable?

    private init() {
        loadHistory()
        setupDebouncedSave()
    }

    // MARK: - Computed

    var menuBarIcon: String {
        if error != nil { return "exclamationmark.circle" }
        if isRecording { return "record.circle.fill" }
        if isTranscribing { return "ellipsis.circle" }
        return "waveform.circle"
    }

    var totalWords: Int {
        transcriptions.reduce(0) { $0 + $1.wordCount }
    }

    var groupedByDate: [(key: String, value: [Transcription])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: transcriptions) { entry -> String in
            if cal.isDateInToday(entry.timestamp) { return "Today" }
            if cal.isDateInYesterday(entry.timestamp) { return "Yesterday" }
            let f = DateFormatter()
            f.dateFormat = "MMMM d, yyyy"
            return f.string(from: entry.timestamp)
        }
        return grouped.sorted { a, b in
            (a.value.first?.timestamp ?? .distantPast) > (b.value.first?.timestamp ?? .distantPast)
        }
    }

    // MARK: - Mutations

    func addTranscription(_ text: String) {
        transcriptions.insert(Transcription(text: text), at: 0)
        // Cap at 500 entries
        if transcriptions.count > Self.maxHistoryEntries {
            transcriptions = Array(transcriptions.prefix(Self.maxHistoryEntries))
        }
        saveSubject.send()
    }

    func deleteTranscription(id: UUID) {
        transcriptions.removeAll { $0.id == id }
        saveSubject.send()
    }

    func clearAllTranscriptions() {
        transcriptions.removeAll()
        saveSubject.send()
    }

    /// Sets `status` and auto-clears after 5 seconds.
    func setTransientStatus(_ message: String) {
        status = message
        statusClearTimer?.cancel()
        statusClearTimer = Just(())
            .delay(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] in
                if self?.status == message { self?.status = nil }
            }
    }

    /// Sets `error` and auto-clears after 5 seconds.
    func setTransientError(_ message: String) {
        error = message
        errorClearTimer?.cancel()
        errorClearTimer = Just(())
            .delay(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] in
                if self?.error == message { self?.error = nil }
            }
    }

    // MARK: - Persistence

    private func setupDebouncedSave() {
        saveCancellable = saveSubject
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] in self?.persistHistoryToDisk() }
    }

    private func persistHistoryToDisk() {
        guard let data = try? JSONEncoder().encode(transcriptions) else { return }
        try? data.write(to: Self.historyFileURL, options: .atomic)
    }

    private func loadHistory() {
        // Try JSON file first (new path)
        if let data = try? Data(contentsOf: Self.historyFileURL),
           let saved = try? JSONDecoder().decode([Transcription].self, from: data) {
            transcriptions = Array(saved.prefix(Self.maxHistoryEntries))
            return
        }

        // Migration: fall back to UserDefaults (old path) and write to disk
        if let data = UserDefaults.standard.data(forKey: "transcriptionHistory"),
           let saved = try? JSONDecoder().decode([Transcription].self, from: data) {
            transcriptions = Array(saved.prefix(Self.maxHistoryEntries))
            // Persist to new location so next launch uses the file
            saveSubject.send()
            // Leave UserDefaults intact — don't delete in case of rollback
        }
    }
}
