import Foundation

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
    /// Concrete aliases of `Host` blocks, in order. Wildcards (`*`, `?`) and negations (`!`) are skipped.
    /// `HostName`, `User` and `Port` count for the aliases of the block they sit in. A `Match` block ends
    /// the `Host` block. `Include` is not followed.
    public static func hostEntries(configText: String) -> [SSHHostEntry] {
        var entries: [SSHHostEntry] = []
        var current: [Int] = []
        for line in configText.split(whereSeparator: \.isNewline) {
            guard let parsed = parseLine(String(line)) else { continue }
            let (key, value) = parsed
            switch key {
            case "host":
                current = []
                for alias in value.split(whereSeparator: \.isWhitespace).map(String.init) {
                    guard SSHTarget.isSafeName(alias), !entries.contains(where: { $0.alias == alias }) else {
                        continue
                    }
                    entries.append(SSHHostEntry(alias: alias, hostName: nil, user: nil, port: nil))
                    current.append(entries.count - 1)
                }
            case "match":
                current = []
            case "hostname":
                for index in current { entries[index].hostName = value }
            case "user":
                for index in current { entries[index].user = value }
            case "port":
                if let port = Int(value) {
                    for index in current { entries[index].port = port }
                }
            default:
                break
            }
        }
        return entries
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

    /// `key value` or `key=value`, with the key lowercased and quotes removed from the value. Nil for
    /// comments, blank lines and lines without a value.
    private static func parseLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "="))
        guard let split = trimmed.rangeOfCharacter(from: separators) else { return nil }
        let key = trimmed[..<split.lowerBound].lowercased()
        var value = trimmed[split.upperBound...].trimmingCharacters(in: separators)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
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
