import XCTest

/// The system log ends up in sysdiagnose and Console, and the README promises
/// "never your words". NSLog may carry lengths and codes, never the dictated
/// text, learned words, or a server body that can echo them.
final class NoDictationInLogsTests: XCTestCase {

    /// Variables that hold what the user said or a body that can repeat it.
    private let contentNames: Set<String> = [
        "finalText", "text", "transcript", "rawBody", "wrong", "right", "w", "term",
        "reversed.right",
    ]

    func testNSLogNeverTakesDictatedTextAsAnArgument() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "no sources found at \(sources.path)")

        var leaks: [String] = []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
            for args in Self.nslogArguments(in: code) where contentNames.contains(args) {
                leaks.append("\(file.lastPathComponent): NSLog(…, \(args))")
            }
        }
        XCTAssertEqual(leaks, [], "log a length or count instead")
    }

    /// Arguments after the format string of every `NSLog(...)` call, trimmed.
    static func nslogArguments(in code: String) -> [String] {
        var out: [String] = []
        var rest = code[...]
        while let start = rest.range(of: "NSLog(") {
            var depth = 1, inString = false, escaped = false
            var current = "", args: [String] = []
            var i = start.upperBound
            while i < rest.endIndex, depth > 0 {
                let c = rest[i]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    current.append(c)
                } else if c == "\"" {
                    inString = true; current.append(c)
                } else if c == "(" {
                    depth += 1; current.append(c)
                } else if c == ")" {
                    depth -= 1
                    if depth > 0 { current.append(c) }
                } else if c == ",", depth == 1 {
                    args.append(current); current = ""
                } else {
                    current.append(c)
                }
                i = rest.index(after: i)
            }
            args.append(current)
            out += args.dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            rest = rest[i...]
        }
        return out
    }

    func testParserSeesMultilineArguments() {
        let code = "NSLog(\"a %@ b %d\",\n  finalText,\n  n.count)"
        XCTAssertEqual(Self.nslogArguments(in: code), ["finalText", "n.count"])
    }
}
