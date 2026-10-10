import Foundation

// Copies of the server's database (docs/ARCHITECTURE.md#backups). Needs the `backups` feature in `daemon.info`.

/// One copy of the database on the server, as `backups.list` reports it. Newest first in the list.
public struct DatabaseBackup: Codable, Sendable, Hashable, Identifiable {
    /// The file name, `bandito-<UTC time>-<reason>.db`. Unique on the server.
    public var name: String
    public var size: Int64
    /// The time of the copy (Unix milliseconds, from its name).
    public var createdAtMs: Int64
    /// `start`, `upgrade`, `daily`, `manual` or `before-restore`; `replaced` or `broken` for a database a restore set
    /// aside (the daemon never deletes those); a newer daemon may send more.
    public var reason: String

    public var id: String { name }

    public var createdAt: Date { Date(timeIntervalSince1970: Double(createdAtMs) / 1000) }
}

/// The result of the last restore the daemon applied at a start (`daemon.info.last_restore`). `ok` says whether the
/// restore happened, `error` says why not. A new start alone does not prove a restore.
public struct LastRestore: Codable, Sendable, Hashable {
    /// The copy the request named.
    public var name: String
    public var ok: Bool
    /// One short sentence, when `ok` is false.
    public var error: String?
    /// When the daemon applied it (Unix milliseconds).
    public var atMs: Int64
    /// The id of the operation: the one `backups.restore` returned. Empty or missing in a record from an older
    /// daemon; the app then falls back to comparing the record with the one it saw before.
    public var id: String?
}

/// The reply to `backups.restore`: the daemon answers first, then restarts.
public struct BackupRestoreReply: Codable, Sendable, Hashable {
    public var restarting: Bool
    /// The id of this restore; `daemon.info.lastRestore.id` carries it back. Missing on older daemons.
    public var id: String?
}

extension ServerModel {
    /// Every copy in the server's backups folder, newest first.
    public func backups() async throws -> [DatabaseBackup] {
        try await rpc().call("backups.list", NoParams(), as: [DatabaseBackup].self)
    }

    /// Makes a copy now (reason `manual`) and returns it. The copy takes a moment for a large database.
    @discardableResult
    public func createBackup() async throws -> DatabaseBackup {
        try await rpc().call("backups.create", NoParams(), as: DatabaseBackup.self, timeout: .seconds(120))
    }

    /// Asks the daemon to restore `name` at its restart. The daemon keeps the current database as a copy first.
    /// The reply comes before the restart, so the link drops right after; the caller waits for a new start.
    /// Returns whether the daemon restarts (it always does when the call succeeds).
    public func restoreBackup(name: String) async throws -> Bool {
        try await requestRestore(name: name).restarting
    }

    /// Like `restoreBackup`, and returns the whole reply: its `id` names this operation, so the result can be told
    /// from an older one once the server is back.
    public func requestRestore(name: String) async throws -> BackupRestoreReply {
        struct P: Encodable { var name: String }
        return try await rpc().call("backups.restore", P(name: name), as: BackupRestoreReply.self)
    }

    /// Asks the daemon to leave safe mode. It first opens a private copy of the database and refuses when that fails
    /// ("restore a copy instead"); otherwise it answers and restarts, so the caller waits for a new start.
    public func leaveSafeMode() async throws {
        struct Reply: Decodable { var restarting: Bool }
        _ = try await rpc().call("backups.leave_safe_mode", NoParams(), as: Reply.self, timeout: .seconds(60))
    }
}
