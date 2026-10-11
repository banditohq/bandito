import Foundation

// Sharing bots and skills (docs/ARCHITECTURE.md#sharing). Needs the `sharing` feature in `daemon.info`.
// A payload is sent and received as JSON with its keys untouched: `callRawResult` and `JSONValue`, never the
// snake_case conversion of `RPCClient`, which would rewrite `system_prompt` and the names of the files.

/// Why the daemon refused a shared item: `-32027` with `data.reason` for a folder or file, `-32602` for the payload
/// (`invalid: <field>`), anything else as the daemon's message.
public enum SharedInstallFailure: Error, Sendable, Equatable {
    /// `data.reason`: `catalog_skill`, `not_yours`, `license_required`, `no_skill`, `unsafe_path`, `bad_path`,
    /// `not_utf8`, `too_large`, `exists_not_ours`, `io`, or a reason a newer daemon adds.
    case reason(String)
    /// The payload has a field the daemon does not accept.
    case invalid(field: String)
    case other(String)

    public init(_ error: RPCError) {
        switch error.code {
        case RPCError.commandsError:
            self = .reason(error.reason ?? "io")
        case RPCError.invalidParams:
            let prefix = "invalid: "
            if error.message.hasPrefix(prefix) {
                self = .invalid(field: String(error.message.dropFirst(prefix.count)))
            } else {
                self = .other(error.message)
            }
        default:
            self = .other(error.message)
        }
    }
}

/// One step of a bot made from a share that went wrong. The bot exists anyway; the step is named here.
public struct SharedStepError: Decodable, Sendable, Hashable {
    /// `agent`, `schedule`, `skill` or `integrations`.
    public var step: String
    public var message: String
}

/// The answer to `agents.create_from_shared`. Missing or unknown services are the catalog ids the bot named that this
/// server does not have or does not connect.
public struct SharedBotCreation: Decodable, Sendable {
    public var agent: Agent?
    public var scheduleIds: [String]
    public var unknownServices: [String]
    public var missingServices: [String]
    public var errors: [SharedStepError]
    public var starter: String?

    public init(
        agent: Agent?, scheduleIds: [String] = [], unknownServices: [String] = [], missingServices: [String] = [],
        errors: [SharedStepError] = [], starter: String? = nil
    ) {
        self.agent = agent
        self.scheduleIds = scheduleIds
        self.unknownServices = unknownServices
        self.missingServices = missingServices
        self.errors = errors
        self.starter = starter
    }
}

/// The `{payload}` answer of `agents.export`.
private struct ExportedPayload: Decodable {
    var payload: JSONValue
}

/// What `skills.export` answers: the skill as it is shared, and the dot files of its folder that were left out, by
/// name, so the owner sees them before publishing. Decoded with a plain `JSONDecoder`: the keys of the payload are data.
public struct SkillExport: Decodable, Sendable, Equatable {
    public var payload: JSONValue
    public var skipped: [String]

    public init(payload: JSONValue, skipped: [String]) {
        self.payload = payload
        self.skipped = skipped
    }

    private enum CodingKeys: String, CodingKey {
        case payload, skipped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        payload = try c.decode(JSONValue.self, forKey: .payload)
        skipped = try c.decodeIfPresent([String].self, forKey: .skipped) ?? []
    }
}

/// One skill of the owner's folder, as `skills.own` lists it. `source` is `own`, or `shared:<share id>` for a copy
/// installed from a link. `version` is the shared install's version (nil for the owner's own skill).
public struct OwnSkill: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var source: String
    public var version: Int?
    public var hasScripts: Bool
    /// The number of files `skills.export` would send.
    public var files: Int

    public var id: String { name }

    public init(name: String, description: String, source: String, version: Int?, hasScripts: Bool, files: Int) {
        self.name = name
        self.description = description
        self.source = source
        self.version = version
        self.hasScripts = hasScripts
        self.files = files
    }
}

private struct OwnSkillsReply: Decodable {
    var skills: [OwnSkill]
}

private struct NoOwnParams: Encodable {}

private struct ExportAgentParams: Encodable {
    var agentID: String

    private enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
    }
}

private struct ExportSkillParams: Encodable {
    var name: String
    var license: String
}

private struct CreateFromSharedParams: Encodable {
    var shareID: String
    var version: Int
    var payload: JSONValue
    var language: String?
    /// The capabilities the owner chose: a subset of the payload's. Nil sends no list (the daemon's default).
    var capabilities: [String]?

    private enum CodingKeys: String, CodingKey {
        case shareID = "share_id"
        case version, payload, language, capabilities
    }
}

private struct InstallSharedParams: Encodable {
    var shareID: String
    var version: Int
    var payload: JSONValue
    var agentID: String?

    private enum CodingKeys: String, CodingKey {
        case shareID = "share_id"
        case version, payload
        case agentID = "agent_id"
    }
}

extension ServerModel {
    /// The bot of an agent as it is shared (`agents.export`): no secret, memory, folder or account. Its payload's
    /// services are the catalog ids of the integrations the agent may use.
    public func exportBot(agentID: String) async throws -> JSONValue {
        let bytes = try await sharingCall("agents.export", ExportAgentParams(agentID: agentID))
        return try JSONDecoder().decode(ExportedPayload.self, from: bytes).payload
    }

    /// A skill folder of the daemon user as it is shared (`skills.export`). Bundled catalog skills are refused
    /// (`catalog_skill`); a binary or big file is an error that names its path.
    public func exportSkill(name: String, license: String) async throws -> SkillExport {
        let bytes = try await sharingCall("skills.export", ExportSkillParams(name: name, license: license))
        return try JSONDecoder().decode(SkillExport.self, from: bytes)
    }

    /// The owner's skills in the daemon user's folder (`skills.own`): the own ones and the copies of shared links.
    /// Catalog installs are not in it. Needs the `sharing` feature.
    public func ownSkills() async throws -> [OwnSkill] {
        try await rpc().call("skills.own", NoOwnParams(), as: OwnSkillsReply.self).skills
    }

    /// Makes an agent from a shared bot (`agents.create_from_shared`), marked `shared:<share id>`. The new agent joins
    /// the list here at once. Steps that fail do not undo the agent: their messages are in `errors`.
    @discardableResult
    public func createBotFromShare(
        shareID: String, version: Int, payload: JSONValue, language: String?, capabilities: [String]?
    ) async throws -> SharedBotCreation {
        let params = CreateFromSharedParams(
            shareID: shareID, version: version, payload: payload, language: language, capabilities: capabilities)
        let bytes = try await sharingCall("agents.create_from_shared", params)
        let created = try RPCClient.decoder.decode(SharedBotCreation.self, from: bytes)
        if let agent = created.agent { replaceAgent(agent) }
        return created
    }

    /// Installs a shared skill (`skills.install_shared`): the daemon user's folder, or the agent's when `agentID` is
    /// given. It never replaces a folder that is not Bandito's (`exists_not_ours`).
    public func installSharedSkill(shareID: String, version: Int, payload: JSONValue, agentID: String? = nil) async throws {
        let params = InstallSharedParams(shareID: shareID, version: version, payload: payload, agentID: agentID)
        _ = try await sharingCall("skills.install_shared", params)
    }

    /// One daemon call with plain JSON params (keys as they are) and the answer's raw JSON. A refusal comes out as
    /// `RPCError`; `SharedInstallFailure(_:)` names it for the screen.
    private func sharingCall(_ method: String, _ params: some Encodable) async throws -> Data {
        let json = try JSONEncoder().encode(params)
        return try await rpc().callRawResult(method, jsonParams: json, timeout: .seconds(60))
    }
}
