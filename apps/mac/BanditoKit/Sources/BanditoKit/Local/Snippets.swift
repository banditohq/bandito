import Foundation

/// A saved prompt with `{placeholders}`. Kept on this Mac in UserDefaults (`snippets.v1`).
public struct Snippet: Codable, Sendable, Identifiable, Hashable {
    /// The name after the slash, e.g. `standup`.
    public var name: String
    public var text: String

    public var id: String { name }

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public enum SnippetStore {
    public static let key = "snippets.v1"

    public static func load(_ defaults: UserDefaults = .standard) -> [Snippet] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Snippet].self, from: data)) ?? []
    }

    public static func save(_ snippets: [Snippet], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        defaults.set(data, forKey: key)
    }
}

/// A `{name}` placeholder inside a snippet. `range` counts characters from the start of the snippet text.
public struct SnippetPlaceholder: Equatable, Sendable {
    public let name: String
    public let range: Range<Int>
}

/// The text a snippet adds to a draft, and the part of it to select (the first placeholder).
public struct SnippetInsertion: Equatable, Sendable {
    public let text: String
    /// Character offsets into `text`. `nil` when the snippet has no placeholder.
    public let selection: Range<Int>?
}

public enum SnippetTemplate {
    public static func placeholders(in text: String) -> [SnippetPlaceholder] {
        text.matches(of: /\{([A-Za-z][A-Za-z0-9_-]*)\}/).map { match in
            let lower = text.distance(from: text.startIndex, to: match.range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: match.range.upperBound)
            return SnippetPlaceholder(name: String(match.output.1), range: lower..<upper)
        }
    }

    /// Appends `template` to `draft`, after a space when the draft does not end in one.
    public static func insert(_ template: String, into draft: String) -> SnippetInsertion {
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        let offset = draft.count + separator.count
        let selection = placeholders(in: template).first.map {
            ($0.range.lowerBound + offset)..<($0.range.upperBound + offset)
        }
        return SnippetInsertion(text: draft + separator + template, selection: selection)
    }
}
