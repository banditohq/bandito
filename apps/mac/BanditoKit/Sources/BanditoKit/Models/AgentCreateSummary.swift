import Foundation

// What an agent that wants to create another agent shows on the approval card: docs/ARCHITECTURE.md#agents-creating-agents.

/// The summary the daemon sends as the `input` of an `agent.create` approval. Read from the event's dynamic JSON,
/// whose object keys the RPC decoder has turned into camelCase; the snake_case spelling is read too, so a summary
/// that came another way (a stored payload) reads the same.
public struct AgentCreateSummary: Sendable, Hashable {
    /// The `tool` of the approval this summary belongs to.
    public static let tool = "agent.create"

    /// One regular run of the new agent.
    public struct Run: Sendable, Hashable {
        public var title: String?
        public var prompt: String
        public var humanEn: String
        public var humanRu: String

        /// The timing in words for the app's language; English for any language but Russian. Empty when the daemon
        /// gave none.
        public func timing(languageCode: String) -> String {
            let russian = languageCode.lowercased().hasPrefix("ru")
            let text = russian ? humanRu : humanEn
            return text.isEmpty ? humanEn : text
        }

        /// What the run is called in a list: its title, else the start of its prompt.
        public var shownName: String {
            if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
            return prompt
        }
    }

    public var name: String
    public var role: String
    public var runtime: String
    public var model: String?
    public var effort: String?
    public var approvalMode: ApprovalMode
    /// Wire names of the capabilities the new agent gets (`terminal`, `files`, `browser`, `team`, `screen`).
    public var capabilities: [String]
    /// Names of the services it may use.
    public var services: [String]
    /// True when the agent gets every enabled service (so `services` is what that means now).
    public var servicesAll: Bool
    public var runs: [Run]
    /// True for a folder of its own that is made with the agent.
    public var folderIsNew: Bool
    public var folderPath: String
    /// The start of its instructions.
    public var instructions: String
    /// The name of the agent that asks.
    public var creator: String

    /// `nil` unless `input` is an object with a name.
    public init?(input: JSONValue?) {
        guard let input, case .object = input, let name = Self.text(input, "name"), !name.isEmpty else { return nil }
        self.name = name
        role = Self.text(input, "role") ?? ""
        runtime = Self.text(input, "runtime") ?? ""
        model = Self.text(input, "model").flatMap { $0.isEmpty ? nil : $0 }
        effort = Self.text(input, "effort").flatMap { $0.isEmpty ? nil : $0 }
        approvalMode = ApprovalMode(rawValue: Self.text(input, "approvalMode", "approval_mode") ?? "") ?? .fallback
        capabilities = Self.strings(input, "capabilities")
        services = Self.strings(input, "integrations")
        servicesAll = Self.flag(input, "integrationsAll", "integrations_all")
        runs = Self.list(input, "schedules").map { item in
            Run(
                title: Self.text(item, "title").flatMap { $0.isEmpty ? nil : $0 },
                prompt: Self.text(item, "prompt") ?? "",
                humanEn: Self.text(item, "humanEn", "human_en") ?? "",
                humanRu: Self.text(item, "humanRu", "human_ru") ?? "")
        }
        let folder = input["folder"]
        folderIsNew = folder.flatMap { Self.text($0, "mode") } != "existing"
        folderPath = folder.flatMap { Self.text($0, "path") } ?? ""
        instructions = Self.text(input, "instructions") ?? ""
        creator = Self.text(input, "creator") ?? ""
    }

    private static func value(_ v: JSONValue, _ keys: [String]) -> JSONValue? {
        for key in keys {
            if let found = v[key] { return found }
        }
        return nil
    }

    private static func text(_ v: JSONValue, _ keys: String...) -> String? {
        value(v, keys)?.string
    }

    private static func flag(_ v: JSONValue, _ keys: String...) -> Bool {
        if case .bool(let b)? = value(v, keys) { return b }
        return false
    }

    private static func list(_ v: JSONValue, _ keys: String...) -> [JSONValue] {
        if case .array(let items)? = value(v, keys) { return items }
        return []
    }

    private static func strings(_ v: JSONValue, _ keys: String...) -> [String] {
        list(v, keys[0]).compactMap(\.string)
    }
}
