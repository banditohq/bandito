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

/// Which mentions of an undelivered message can go again. The daemon refuses a message with a mention it cannot
/// keep, so what is gone is left out instead of failing the whole send.
public struct MentionResend: Sendable, Equatable {
    public var kept: [Mention]
    public var dropped: [Mention]

    /// `integrations` are the ids the agent may use now, `agents` the ids of the crew, `tabs` the open pages of the
    /// browser (nil: not known, so tab mentions are left out), `files` the paths that still exist.
    public static func split(
        _ mentions: [Mention], integrations: Set<String>, agents: Set<String>, tabs: Set<String>?, files: Set<String>
    ) -> MentionResend {
        var kept: [Mention] = []
        var dropped: [Mention] = []
        for mention in mentions {
            let ok: Bool
            switch mention.kind {
            case .integration: ok = integrations.contains(mention.id)
            case .agent: ok = agents.contains(mention.id)
            case .file: ok = files.contains(mention.id)
            case .browserTab: ok = tabs?.contains(mention.id) ?? false
            }
            if ok { kept.append(mention) } else { dropped.append(mention) }
        }
        return MentionResend(kept: kept, dropped: dropped)
    }
}
