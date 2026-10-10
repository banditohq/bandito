import Foundation

/// The YAML block at the top of a Claude Code file (`---` … `---`) and what follows it. Reads what these files use: a
/// `key: value` line (the value may be in quotes), an inline list `[a, b]`, a list of `- item` lines under the key, and a
/// block of text after `|` or `>`. Anything deeper is not read. Pure, so it is tested without a file system.
public struct ImportFrontMatter: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case text(String)
        case list([String])

        /// The value as one line of text: a list is joined with commas.
        public var asText: String {
            switch self {
            case .text(let text): text
            case .list(let items): items.joined(separator: ", ")
            }
        }

        /// The value as a list: a text is split at commas (`tools: Read, Grep`), a list is as it is. Empty items go.
        public var asList: [String] {
            switch self {
            case .text(let text): text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .list(let items): items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
    }

    /// The keys in the order the file has them, so a preview shows them as the person wrote them.
    public var keys: [String]
    public var fields: [String: Value]
    /// What follows the block, or the whole text when there is no block.
    public var body: String
    /// The block as it is in the file, for a preview; empty when there is none.
    public var raw: String

    public subscript(key: String) -> Value? { fields[key] }

    /// The text of a key, nil when it is missing or empty.
    public func text(_ key: String) -> String? {
        guard let value = fields[key]?.asText.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public static func parse(_ text: String) -> ImportFrontMatter {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A byte order mark in front of the first line.
        if lines.first?.hasPrefix("\u{FEFF}") == true { lines[0].removeFirst() }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
            let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            return ImportFrontMatter(keys: [], fields: [:], body: normalized, raw: "")
        }
        let block = Array(lines[1..<end])
        let body = lines[(end + 1)...].joined(separator: "\n")
        var keys: [String] = []
        var fields: [String: Value] = [:]
        var index = 0
        while index < block.count {
            let line = block[index]
            index += 1
            guard let first = line.first, !first.isWhitespace, first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // The lines indented under the key.
            var nested: [String] = []
            while index < block.count, block[index].isEmpty || block[index].first?.isWhitespace == true {
                nested.append(block[index])
                index += 1
            }
            guard !key.isEmpty else { continue }
            let value: Value?
            if rest == "|" || rest == ">" || rest.hasPrefix("|-") || rest.hasPrefix(">-") || rest.hasPrefix("|+") || rest.hasPrefix(">+") {
                value = .text(blockText(nested, folded: rest.hasPrefix(">")))
            } else if rest.isEmpty {
                let items = nested.compactMap(listItem)
                value = items.isEmpty ? nil : .list(items)
            } else if rest.hasPrefix("["), rest.hasSuffix("]") {
                let inner = rest.dropFirst().dropLast()
                value = .list(inner.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty })
            } else {
                // A plain value that goes on over indented lines is read as one line.
                let more = nested.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                value = .text(unquote(([rest] + more).joined(separator: " ")))
            }
            if let value, !value.asText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if fields[key] == nil { keys.append(key) }
                fields[key] = value
            }
        }
        return ImportFrontMatter(keys: keys, fields: fields, body: body, raw: block.joined(separator: "\n"))
    }

    /// `- item` of a list under a key.
    private static func listItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("-") else { return nil }
        let item = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
        return item.isEmpty ? nil : item
    }

    /// The text of a `|` or `>` block: its lines without the common indent; a folded block joins the lines with spaces.
    private static func blockText(_ lines: [String], folded: Bool) -> String {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let stripped = lines.map { $0.count >= indent ? String($0.dropFirst(indent)) : "" }
        let text = folded
            ? stripped.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            : stripped.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes one pair of matching quotes. In double quotes a few escapes are read (`\"`, `\\`, `\n`).
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return value }
        let inner = String(value.dropFirst().dropLast())
        if quote == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        return inner.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
