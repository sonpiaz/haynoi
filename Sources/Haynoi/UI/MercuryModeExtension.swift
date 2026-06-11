import Foundation

// MARK: - Mercury-specific TranscriptionMode display extension

extension TranscriptionMode {
    /// One-line pill description for the Mercury mode grid in the context panel.
    var shortDescription: String {
        switch self {
        case .auto:   return "Adapts to each app"
        case .normal: return "Verbatim"
        case .clean:  return "Removes filler"
        case .email:  return "Formal prose"
        }
    }
}
