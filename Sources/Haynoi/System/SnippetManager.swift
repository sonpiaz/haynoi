import Foundation

struct Snippet: Codable, Identifiable {
    let id: UUID
    var trigger: String   // voice trigger word, e.g. "lịch"
    var expansion: String // expanded text, e.g. "https://cal.com/son"

    init(trigger: String, expansion: String) {
        self.id = UUID()
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// Voice shortcuts: if transcribed text contains a trigger word, replace with expansion.
enum SnippetManager {
    private static let key = "snippets"

    static var snippets: [Snippet] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([Snippet].self, from: data) else { return [] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    static func add(_ snippet: Snippet) {
        var list = snippets
        list.append(snippet)
        snippets = list
    }

    static func remove(id: UUID) {
        snippets = snippets.filter { $0.id != id }
    }

    /// Apply snippet expansions to transcribed text.
    /// If the ENTIRE text matches a trigger (case-insensitive), replace with expansion.
    /// Also checks if text starts with trigger.
    static func applySnippets(to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        for snippet in snippets {
            let trigger = snippet.trigger.lowercased()
            // Exact match
            if lower == trigger { return snippet.expansion }
            // Starts with trigger + space
            if lower.hasPrefix(trigger + " ") {
                let rest = String(trimmed.dropFirst(snippet.trigger.count + 1))
                return snippet.expansion + " " + rest
            }
        }
        return text
    }
}
