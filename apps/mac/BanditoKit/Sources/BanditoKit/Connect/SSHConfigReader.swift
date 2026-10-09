import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One concrete `Host` alias of `~/.ssh/config`, with the settings that apply to it.
public struct SSHHostEntry: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?

    public init(alias: String, hostName: String?, user: String?, port: Int?) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
    }
}

/// Reads `~/.ssh/config` and `~/.ssh/known_hosts` to suggest addresses for the connect field.
/// It only reads text: the files themselves are never written.
public enum SSHConfigReader {
    /// How deep `Include` may nest. A file read at this depth does not include anything further.
    static let maxIncludeDepth = 8

    /// The directory that relative `Include` paths are read from: `~/.ssh`.
    public static var defaultSSHDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appending(path: ".ssh", directoryHint: .isDirectory)
    }

    /// Concrete aliases of `Host` blocks, in order. Wildcards (`*`, `?`) and negations (`!`) are skipped.
    /// `HostName`, `User` and `Port` count for the aliases of the block they sit in. A `Match` block ends
    /// the `Host` block.
    ///
    /// `Include` is followed like ssh does: the files it names are read as if their lines stood at that place,
    /// relative paths from `sshDirectory`, `~/` from the home folder, and globs (`conf.d/*.conf`) in sorted order.
    /// A file is read once, and nesting stops at `maxIncludeDepth`, so an include cycle cannot loop. A missing file
    /// is skipped. Settings from an included file apply to the `Host` block that contains the `Include`.
    public static func hostEntries(
        configText: String, sshDirectory: URL = defaultSSHDirectory
    ) -> [SSHHostEntry] {
        var entries: [SSHHostEntry] = []
        var visited: Set<String> = []
        var current: [Int] = []
        collect(
            configText: configText, sshDirectory: sshDirectory, depth: 0,
            visited: &visited, entries: &entries, current: &current)
        return entries
    }

    private static func collect(
        configText: String, sshDirectory: URL, depth: Int,
        visited: inout Set<String>, entries: inout [SSHHostEntry], current: inout [Int]
    ) {
        for line in configText.split(whereSeparator: \.isNewline) {
            guard let parsed = parseLine(String(line)) else { continue }
            let (key, value) = parsed
            switch key {
            case "host":
                current = []
                for alias in words(value) {
                    guard SSHTarget.isSafeName(alias), !entries.contains(where: { $0.alias == alias }) else {
                        continue
                    }
                    entries.append(SSHHostEntry(alias: alias, hostName: nil, user: nil, port: nil))
                    current.append(entries.count - 1)
                }
            case "match":
                current = []
            case "hostname":
                guard let name = words(value).first else { break }
                for index in current { entries[index].hostName = name }
            case "user":
                guard let name = words(value).first else { break }
                for index in current { entries[index].user = name }
            case "port":
                if let port = words(value).first.flatMap({ Int($0) }) {
                    for index in current { entries[index].port = port }
                }
            case "include":
                guard depth < maxIncludeDepth else { break }
                for pattern in words(value) {
                    for path in includedPaths(pattern, sshDirectory: sshDirectory) where !visited.contains(path) {
                        visited.insert(path)
                        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                        // The included lines start from the block that holds the Include; the block is
                        // restored afterwards, as ssh does.
                        var inner = current
                        collect(
                            configText: text, sshDirectory: sshDirectory, depth: depth + 1,
                            visited: &visited, entries: &entries, current: &inner)
                    }
                }
            default:
                break
            }
        }
    }

    /// The words of a value: split at spaces and tabs, except inside double quotes, where a run of text stays one word.
    /// The quotes themselves are removed. `"my box" other` gives `my box` and `other`.
    static func words(_ value: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
                inWord = true
            } else if character.isWhitespace && !quoted {
                if inWord {
                    words.append(word)
                    word = ""
                    inWord = false
                }
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }

    /// The files one `Include` pattern names, as absolute paths in sorted order. A pattern without a glob is one path,
    /// whether or not the file exists.
    private static func includedPaths(_ pattern: String, sshDirectory: URL) -> [String] {
        var path = pattern
        if path.hasPrefix("~/") {
            path = NSHomeDirectory() + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = sshDirectory.appending(path: path).path
        }
        guard path.contains(where: { "*?[".contains($0) }) else { return [path] }
        return globMatches(path)
    }

    /// Paths matching a shell glob, sorted. Nothing when the pattern matches nothing.
    private static func globMatches(_ pattern: String) -> [String] {
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(pattern, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }

    /// Host names from `known_hosts`, as `host` or `host:port` (for `[host]:port`). Hashed entries (`|1|…`),
    /// markers (`@cert-authority`, `@revoked`) and wildcard patterns are skipped. Duplicates are dropped.
    public static func knownHosts(_ text: String) -> [String] {
        var hosts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("|"), !trimmed.hasPrefix("@"),
                let field = trimmed.split(whereSeparator: \.isWhitespace).first
            else { continue }
            for pattern in field.split(separator: ",") {
                guard let entry = knownHostEntry(String(pattern)), !hosts.contains(entry) else { continue }
                hosts.append(entry)
            }
        }
        return hosts
    }

    /// Suggestions for the address field: config aliases first, then known hosts that are not aliases.
    public static func suggestions(config: String, knownHosts: String) -> [String] {
        var result: [String] = []
        let candidates = hostEntries(configText: config).map(\.alias) + Self.knownHosts(knownHosts)
        for candidate in candidates where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }

    /// `key value` or `key=value`, with the key lowercased. The value keeps its quotes: `words` reads them. Nil for
    /// comments, blank lines and lines without a value.
    private static func parseLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let split = trimmed.rangeOfCharacter(from: separators) else { return nil }
        let key = trimmed[..<split.lowerBound].lowercased()
        var value = trimmed[split.upperBound...].trimmingCharacters(in: separators)
        guard !value.isEmpty else { return nil }
        return (key, value)
    }

    /// `host` or `host:port` from a known_hosts pattern. Nil for wildcards and names ssh would not accept.
    private static func knownHostEntry(_ pattern: String) -> String? {
        guard !pattern.contains(where: { "*?!".contains($0) }) else { return nil }
        if pattern.hasPrefix("[") {
            // [host]:port
            guard let close = pattern.firstIndex(of: "]") else { return nil }
            let host = String(pattern[pattern.index(after: pattern.startIndex)..<close])
            let rest = pattern[pattern.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65_535).contains(port),
                SSHTarget.isSafeName(host)
            else { return nil }
            return "\(host):\(port)"
        }
        guard SSHTarget.isSafeName(pattern) else { return nil }
        return pattern
    }
}
