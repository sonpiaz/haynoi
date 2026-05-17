import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case normal = "Normal"
    case clean = "Clean"
    case email = "Email / Formal"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .normal: return "waveform"
        case .clean: return "sparkles"
        case .email: return "envelope"
        }
    }

    var description: String {
        switch self {
        case .auto: return "Auto-detect: Email app → formal, Chat → clean, else normal"
        case .normal: return "Transcribe exactly what you say"
        case .clean: return "Remove filler words (um, uh, à...)"
        case .email: return "Rewrite as professional text"
        }
    }

    /// Prompt for gpt-4o-transcribe (affects raw transcription)
    /// Resolve Auto mode to a concrete mode
    var resolved: TranscriptionMode {
        if self == .auto { return AppStyleDetector.detectMode() }
        return self
    }

    var sttPrompt: String {
        switch self {
        case .auto: return resolved.sttPrompt
        case .normal:
            return "Transcribe this audio accurately. It may contain Vietnamese and English."
        case .clean:
            return "Transcribe this audio accurately. Remove filler words like um, uh, à, ừm. It may contain Vietnamese and English."
        case .email:
            return "Transcribe this audio accurately. It may contain Vietnamese and English."
        }
    }

    /// If true, post-process with GPT-4o to rewrite the text.
    var needsRewrite: Bool {
        (self == .auto ? resolved : self) == .email
    }

    /// System prompt for GPT-4o rewrite (only used for .email mode)
    var rewritePrompt: String {
        """
        Rewrite the following spoken text into a professional, well-structured message. \
        Fix grammar, remove filler words, add proper punctuation. \
        Keep the same language (Vietnamese, English, or mixed). \
        Do not add greetings or signatures unless the speaker included them. \
        Output ONLY the rewritten text, nothing else.
        """
    }

    static var current: TranscriptionMode {
        let raw = UserDefaults.standard.string(forKey: "transcriptionMode") ?? TranscriptionMode.normal.rawValue
        return TranscriptionMode(rawValue: raw) ?? .normal
    }
}
