import Foundation

/// Shared helpers that turn the `hotkeyChoice` UserDefaults key into
/// human-readable UI strings.  Used by ContentView, MainView, and — via the
/// same @AppStorage key — any future surface (onboarding, tooltips).
///
/// The key `"hotkeyChoice"` is owned by SettingsView's @AppStorage binding;
/// we read UserDefaults directly here so non-SwiftUI callers (and views that
/// don't hold a Settings reference) can also access it without duplication.
enum HotkeyDisplay {

    /// The single Unicode modifier glyph, e.g. "⌘", "⌥", "⌃", "fn".
    static var symbol: String {
        switch UserDefaults.standard.string(forKey: "hotkeyChoice") ?? "command" {
        case "option":  return "⌥"
        case "control": return "⌃"
        case "fn":      return "fn"
        default:        return "⌘"
        }
    }

    /// A short prose name, e.g. "Command", "Option", "Control", "Globe".
    static var name: String {
        switch UserDefaults.standard.string(forKey: "hotkeyChoice") ?? "command" {
        case "option":  return "Option"
        case "control": return "Control"
        case "fn":      return "Globe"
        default:        return "Command"
        }
    }

    /// Symbol + name for inline UI copy, e.g. "⌘ Command".
    static var symbolAndName: String { "\(symbol) \(name)" }
}
