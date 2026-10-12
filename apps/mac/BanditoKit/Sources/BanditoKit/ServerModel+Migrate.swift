import Foundation

// Moving an agent from one of the owner's servers to another (docs/ARCHITECTURE.md#agent-migration). The methods need
// the `agent_migrate` feature in `daemon.info`. Replies are decoded with `RPCClient.decoder` (snake_case keys become
// camelCase here); the piece of the archive travels as base64 text and is never decoded by the app.

/// The answer to `agents.migrate_export`: the archive waits under `token` for an hour.
public struct MigrationExport: Decodable, Sendable, Equatable {
    public var token: String
    /// Bytes of the archive.
    public var size: Int64
    /// Hex sha256 of the whole archive.
    public var sha256: String
    /// Memory files packed.
    public var files: Int
    /// History events packed.
    public var events: Int
    /// Entries left out of the archive on the source (a count).
    public var skipped: Int

    public init(token: String, size: Int64, sha256: String, files: Int, events: Int, skipped: Int) {
        self.token = token
        self.size = size
        self.sha256 = sha256
        self.files = files
        self.events = events
        self.skipped = skipped
    }
}

/// One piece of the archive from `agents.migrate_read`. `data` is base64 of the bytes, as the daemon sent them.
public struct MigrationPiece: Decodable, Sendable, Equatable {
    public var data: String
    public var eof: Bool

    public init(data: String, eof: Bool) {
        self.data = data
        self.eof = eof
    }
}

/// The answer to `agents.migrate_done`. `agent` is the source agent's view when `movedTo` was given, else nil.
public struct MigrationDone: Decodable, Sendable {
    public var ok: Bool
    public var agent: Agent?

    public init(ok: Bool, agent: Agent?) {
        self.ok = ok
        self.agent = agent
    }
}

/// A step of the target's commit that went wrong. The agent exists anyway; the step is named here.
public struct MigrationImportError: Decodable, Sendable, Equatable {
    /// `agent`, `memory`, `avatar`, `events`, `schedule` or `integrations`.
    public var step: String
    public var message: String
    public var index: Int?

    public init(step: String, message: String, index: Int? = nil) {
        self.step = step
        self.message = message
        self.index = index
    }
}

/// The answer to `agents.migrate_import_commit`. `skipped` lists the entries the target dropped from the archive
/// (`"<path>: <why>"`); `missingServices` are the catalog ids the agent used there and this server does not connect.
public struct MigrationCommit: Decodable, Sendable, Equatable {
    public var agent: Agent?
    public var missingServices: [String]
    public var grantedServices: [String]
    public var downgraded: [String]
    public var skipped: [String]
    public var scheduleIds: [String]
    public var events: Int
    public var files: Int
    public var errors: [MigrationImportError]

    public init(
        agent: Agent?, missingServices: [String] = [], grantedServices: [String] = [], downgraded: [String] = [],
        skipped: [String] = [], scheduleIds: [String] = [], events: Int = 0, files: Int = 0,
        errors: [MigrationImportError] = []
    ) {
        self.agent = agent
        self.missingServices = missingServices
        self.grantedServices = grantedServices
        self.downgraded = downgraded
        self.skipped = skipped
        self.scheduleIds = scheduleIds
        self.events = events
        self.files = files
        self.errors = errors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(Agent.self, forKey: .agent)
        missingServices = try c.decodeIfPresent([String].self, forKey: .missingServices) ?? []
        grantedServices = try c.decodeIfPresent([String].self, forKey: .grantedServices) ?? []
        downgraded = try c.decodeIfPresent([String].self, forKey: .downgraded) ?? []
        skipped = try c.decodeIfPresent([String].self, forKey: .skipped) ?? []
        scheduleIds = try c.decodeIfPresent([String].self, forKey: .scheduleIds) ?? []
        events = try c.decodeIfPresent(Int.self, forKey: .events) ?? 0
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
        errors = try c.decodeIfPresent([MigrationImportError].self, forKey: .errors) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case agent, missingServices, grantedServices, downgraded, skipped, scheduleIds, events, files, errors
    }
}

private struct MigrateExportParams: Encodable {
    var agentID: String
}

private struct MigrateReadParams: Encodable {
    var token: String
    var offset: Int64
    var length: Int
}

private struct MigrateDoneParams: Encodable {
    var token: String
    var movedTo: String?
}

private struct MigrateImportBeginParams: Encodable {
    var size: Int64
    var sha256: String
}

private struct MigrateImportWriteParams: Encodable {
    var uploadID: String
    var offset: Int64
    var data: String
}

private struct MigrateImportCommitParams: Encodable {
    var uploadID: String
    var cwd: String?
    var name: String?
}

private struct MigrateImportBeginReply: Decodable {
    var uploadId: String
}

private struct MigrateImportWriteReply: Decodable {
    var written: Int64
}

extension ServerModel: MigrationPeer {
    /// The server's name as the owner gave it. The source stores it as `migrated_to` when an agent moves here.
    public var serverName: String { config.name }

    /// Connected right now (a moved agent can be opened on it only then).
    public var isConnected: Bool { state == .connected }

    /// Packs an agent into an archive on this server (`agents.migrate_export`). The agent must not be working or
    /// waiting for the person: the daemon refuses with `agent_busy`. Needs the `agent_migrate` feature.
    public func migrateExport(agentID: String) async throws -> MigrationExport {
        try await rpc().call(
            "agents.migrate_export", MigrateExportParams(agentID: agentID), as: MigrationExport.self,
            timeout: .seconds(600))
    }

    /// One piece of an exported archive (`agents.migrate_read`). `length` is at most 1 MiB.
    public func migrateRead(token: String, offset: Int64, length: Int) async throws -> MigrationPiece {
        try await rpc().call(
            "agents.migrate_read", MigrateReadParams(token: token, offset: offset, length: length),
            as: MigrationPiece.self, timeout: .seconds(60))
    }

    /// Ends an export (`agents.migrate_done`). With `movedTo` the source marks the agent as moved (it is paused and
    /// gets `migratedTo`), and the new view replaces the agent in the list. Without it nothing changes on the source
    /// but the archive, which is deleted. The daemon answers `changed_since_export` when the agent has new events
    /// after the export; then nothing is marked.
    @discardableResult
    public func migrateDone(token: String, movedTo: String?) async throws -> MigrationDone {
        let done = try await rpc().call(
            "agents.migrate_done", MigrateDoneParams(token: token, movedTo: movedTo), as: MigrationDone.self)
        if let agent = done.agent { replaceAgent(agent) }
        return done
    }

    /// Opens an upload on this server (`agents.migrate_import_begin`) and returns its `upload_id`.
    public func migrateImportBegin(size: Int64, sha256: String) async throws -> String {
        try await rpc().call(
            "agents.migrate_import_begin", MigrateImportBeginParams(size: size, sha256: sha256),
            as: MigrateImportBeginReply.self, timeout: .seconds(60)).uploadId
    }

    /// Writes the next piece (`agents.migrate_import_write`). `offset` must be the size written so far; `data` is
    /// base64 as `migrateRead` gave it. Returns the size written so far.
    public func migrateImportWrite(uploadID: String, offset: Int64, data: String) async throws -> Int64 {
        try await rpc().call(
            "agents.migrate_import_write", MigrateImportWriteParams(uploadID: uploadID, offset: offset, data: data),
            as: MigrateImportWriteReply.self, timeout: .seconds(60)).written
    }

    /// Unpacks an upload into a new agent (`agents.migrate_import_commit`). The agent joins this server's list at
    /// once. Steps that fail after the agent is made are listed in the reply's `errors`, not thrown.
    @discardableResult
    public func migrateImportCommit(uploadID: String, cwd: String?, name: String?) async throws -> MigrationCommit {
        let commit = try await rpc().call(
            "agents.migrate_import_commit", MigrateImportCommitParams(uploadID: uploadID, cwd: cwd, name: name),
            as: MigrationCommit.self, timeout: .seconds(600))
        if let agent = commit.agent { replaceAgent(agent) }
        return commit
    }
}
