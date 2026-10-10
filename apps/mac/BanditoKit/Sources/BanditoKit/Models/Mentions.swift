import Foundation

// `@` mentions in a message (feature `mentions`). Source of truth: daemon/src/mentions.rs,
// docs/ARCHITECTURE.md#mentions.

/// What a mention points at. The wire values are snake_case (`browser_tab`).
public enum MentionKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// A connected service. `id` is the integration's id.
    case integration
    /// A teammate. `id` is the agent's id.
    case agent
    /// A file or folder of the agent's folder. `id` is its absolute path on the server.
    case file
    /// A tab of the server's browser. `id` is the tab id.
    case browserTab = "browser_tab"
}

/// One mention: in `agents.send` (`mentions`) and in the `message.user` event the thread keeps. `label` is the text
/// after the `@` in the message.
public struct Mention: Codable, Sendable, Hashable, Identifiable {
    public var kind: MentionKind
    public var id: String
    public var label: String

    public init(kind: MentionKind, id: String, label: String) {
        self.kind = kind
        self.id = id
        self.label = label
    }

    /// The text this mention leaves in the message.
    public var token: String { "@" + label }

    private enum CodingKeys: String, CodingKey {
        case kind, id, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        // A kind this app does not know is read as a file: the chip still shows its label.
        kind = (try? c.decode(MentionKind.self, forKey: .kind)) ?? .file
    }
}
