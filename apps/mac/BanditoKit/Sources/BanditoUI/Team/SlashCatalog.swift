import BanditoKit
import BanditoL10n

/// Where a slash command comes from, as the menu's filters name it.
public enum SlashOrigin: String, CaseIterable, Sendable {
    /// Listed by the daemon for this agent.
    case server
    /// On this Mac, not yet on the server.
    case mac
    /// Built into the app.
    case bandito
    /// A saved snippet.
    case mine
}

/// The filter chips above the menu.
public enum SlashSourceFilter: CaseIterable, Sendable {
    case all, server, mac, bandito, mine

    public func includes(_ origin: SlashOrigin) -> Bool {
        switch self {
        case .all: true
        case .server: origin == .server
        case .mac: origin == .mac
        case .bandito: origin == .bandito
        case .mine: origin == .mine
        }
    }
}

public struct SlashEntry: Identifiable, Hashable, Sendable {
    /// The name after the slash.
    public let name: String
    public let description: String?
    public let argsHint: String?
    public let origin: SlashOrigin
    /// Other words that find the command, in the app's language (`slash.alias.<command>`). The name is the English
    /// one and always finds it.
    public let aliases: [String]

    public var id: String { "\(origin.rawValue):\(name)" }

    public init(name: String, description: String?, argsHint: String?, origin: SlashOrigin, aliases: [String] = []) {
        self.name = name
        self.description = description
        self.argsHint = argsHint
        self.origin = origin
        self.aliases = aliases
    }
}

/// Tells whether the draft is a slash command being typed.
public enum SlashTrigger {
    /// The text after the slash while the name is still being typed. `nil` when the draft does not
    /// start with a slash (leading spaces are fine), or when the name is finished and arguments follow.
    public static func query(for draft: String) -> String? {
        let afterSpaces = draft.drop(while: { $0.isWhitespace })
        guard afterSpaces.first == "/" else { return nil }
        let name = afterSpaces.dropFirst()
        guard !name.contains(where: { $0.isWhitespace }) else { return nil }
        return String(name)
    }
}

/// A finished slash command: `/name args`.
public struct SlashInvocation: Equatable, Sendable {
    public let name: String
    public let args: String

    public init(name: String, args: String) {
        self.name = name
        self.args = args
    }
}

public enum SlashInvocationParser {
    public static func parse(_ text: String) -> SlashInvocation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix(while: { !$0.isWhitespace })
        guard !name.isEmpty else { return nil }
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
        return SlashInvocation(name: String(name), args: args)
    }
}

public enum SlashMatcher {
    /// Entries that the source filter includes and whose name, or an alias, starts with `query` (a word of an alias
    /// counts too). Case and accents do not matter. The input order is kept.
    public static func filter(_ entries: [SlashEntry], query: String, source: SlashSourceFilter) -> [SlashEntry] {
        entries.filter { entry in
            source.includes(entry.origin) && SearchFolding.matches(query: query, candidates: [entry.name] + entry.aliases)
        }
    }
}

/// Commands the app handles itself: `/new`, `/model`, and the rest of the Bandito group.
public enum BuiltinSlash: CaseIterable, Sendable {
    case new, model, effort, memory, changes, terminal, files, usage, pause

    public var name: String {
        switch self {
        case .new: "new"
        case .model: "model"
        case .effort: "effort"
        case .memory: "memory"
        case .changes: "changes"
        case .terminal: "terminal"
        case .files: "files"
        case .usage: "usage"
        case .pause: "pause"
        }
    }

    public static func named(_ name: String) -> BuiltinSlash? {
        allCases.first { $0.name == name }
    }

    /// The effort level named by an argument such as `high`. Case does not matter.
    public static func effortLevel(from text: String) -> Effort? {
        Effort(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public var summary: String {
        switch self {
        case .new: L10n.Slash.newSummary
        case .model: L10n.Slash.modelSummary
        case .effort: L10n.Slash.effortSummary
        case .memory: L10n.Slash.memorySummary
        case .changes: L10n.Slash.changesSummary
        case .terminal: L10n.Slash.terminalSummary
        case .files: L10n.Slash.filesSummary
        case .usage: L10n.Slash.usageSummary
        case .pause: L10n.Slash.pauseSummary
        }
    }

    /// The words that find the command in the app's language (`slash.alias.<command>`), besides its English name.
    public var aliases: [String] {
        SearchFolding.words(aliasText)
    }

    private var aliasText: String {
        switch self {
        case .new: L10n.Slash.Alias.new
        case .model: L10n.Slash.Alias.model
        case .effort: L10n.Slash.Alias.effort
        case .memory: L10n.Slash.Alias.memory
        case .changes: L10n.Slash.Alias.changes
        case .terminal: L10n.Slash.Alias.terminal
        case .files: L10n.Slash.Alias.files
        case .usage: L10n.Slash.Alias.usage
        case .pause: L10n.Slash.Alias.pause
        }
    }

    public var argsHint: String? {
        switch self {
        case .model: "<model>"
        case .effort: "low|medium|high|xhigh|max"
        default: nil
        }
    }
}

/// The full menu list: server commands, commands only on this Mac, built-ins, and snippets.
public enum SlashCatalog {
    public static func entries(server: [AgentCommand], mac: [MacCommand], snippets: [Snippet]) -> [SlashEntry] {
        let onServer = Set(server.map(\.name))
        var entries = server.map {
            SlashEntry(name: $0.name, description: $0.description, argsHint: $0.argsHint, origin: .server)
        }
        entries += mac.filter { !onServer.contains($0.name) }.map {
            SlashEntry(name: $0.name, description: $0.description, argsHint: $0.argsHint, origin: .mac)
        }
        entries += BuiltinSlash.allCases.map {
            SlashEntry(name: $0.name, description: $0.summary, argsHint: $0.argsHint, origin: .bandito, aliases: $0.aliases)
        }
        entries += snippets.map {
            SlashEntry(
                name: $0.name, description: $0.text.split(separator: "\n").first.map(String.init), argsHint: nil,
                origin: .mine)
        }
        return entries
    }
}
