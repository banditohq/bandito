import AppIntents
import Foundation

/// An agent as Shortcuts and Siri name it: "Ask Forge in Bandito". The id is "<serverID>/<agentID>", the same pair the
/// `bandito://agent/...` link and the Spotlight item carry. No address and no token.
struct AgentEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentEntityQuery()

    let serverID: String
    let agentID: String
    let name: String
    let role: String

    var id: String { "\(serverID)/\(agentID)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: role.isEmpty ? nil : "\(role)")
    }

    init(server: String, agent: String, name: String, role: String) {
        serverID = server
        agentID = agent
        self.name = name
        self.role = role
    }
}

/// Finds agents for the intents' pickers. Reads the same directory the Spotlight index does (`AppIntentHub`).
struct AgentEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        let all = await AppIntentHub.shared.agents()
        return AgentDirectory.entities(ids: identifiers, in: all)
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        let all = await AppIntentHub.shared.agents()
        return AgentDirectory.matching(all, text: string)
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        await AppIntentHub.shared.agents()
    }
}

/// The pure rules of the agent list: from the directory to entities, by name, by id. No app state, so tests can run them.
enum AgentDirectory {
    static func entities(_ listing: [WidgetSnapshot.Listing]) -> [AgentEntity] {
        listing.map { AgentEntity(server: $0.server, agent: $0.id, name: $0.name, role: $0.role) }
    }

    /// The agents whose name contains the text, whatever the case and the accents. An empty text finds all of them.
    static func matching(_ entities: [AgentEntity], text: String) -> [AgentEntity] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entities }
        return entities.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The entities with these ids, in the order of the ids; an id that names no agent is left out.
    static func entities(ids: [String], in entities: [AgentEntity]) -> [AgentEntity] {
        let byID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}
