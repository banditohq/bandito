import Foundation

// Bot templates and skills (docs/ARCHITECTURE.md#agent-templates, #skills). Owner and app methods only.

/// Where a skill is installed or removed.
public enum SkillScope: Sendable, Equatable {
    /// The daemon user's folder: every agent on the server that reads `~/.claude/skills`.
    case user
    /// One agent's own folder.
    case agent(String)

    var wire: (scope: String, agentID: String?) {
        switch self {
        case .user: ("user", nil)
        case .agent(let id): ("project", id)
        }
    }
}

/// The body of `skills.install` and `skills.remove`.
struct SkillParams: Encodable, Equatable {
    var skillId: String
    var scope: String
    var agentId: String?

    init(skillID: String, scope: SkillScope) {
        skillId = skillID
        self.scope = scope.wire.scope
        agentId = scope.wire.agentID
    }
}

extension ServerModel {
    /// The templates built into the daemon (`agents.templates`). Needs the `agent_templates` feature.
    public func botTemplates() async throws -> [BotTemplate] {
        try await rpc().call("agents.templates", NoParams(), as: [BotTemplate].self)
    }

    /// Makes an agent from a template (`agents.create_from_template`). Nothing is rolled back when a step after the
    /// agent fails: the answer's `errors` names it. The new agent joins the list here at once.
    public func createBot(_ new: NewBot) async throws -> BotCreation {
        let created = try await rpc().call("agents.create_from_template", new, as: BotCreation.self, timeout: .seconds(60))
        if let agent = created.agent { replaceAgent(agent) }
        return created
    }

    /// The skills catalog with the state of each skill on this server (`skills.catalog`). Needs the `skills` feature.
    public func skillCatalog() async throws -> [SkillEntry] {
        try await rpc().call("skills.catalog", NoParams(), as: [SkillEntry].self)
    }

    /// Installs a bundled skill. The daemon refuses a folder of that name that is not Bandito's.
    public func installSkill(_ skillID: String, scope: SkillScope) async throws {
        try await rpc().call("skills.install", SkillParams(skillID: skillID, scope: scope), timeout: .seconds(60))
    }

    /// Removes a skill Bandito installed.
    public func removeSkill(_ skillID: String, scope: SkillScope) async throws {
        try await rpc().call("skills.remove", SkillParams(skillID: skillID, scope: scope), timeout: .seconds(60))
    }
}
