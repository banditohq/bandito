import Foundation

// Copies of the server's database (docs/ARCHITECTURE.md#backups). Needs the `backups` feature in `daemon.info`.

/// One copy of the database on the server, as `backups.list` reports it. Newest first in the list.
public struct DatabaseBackup: Codable, Sendable, Hashable, Identifiable {
    /// The file name, `bandito-<UTC time>-<reason>.db`. Unique on the server.
    public var name: String
    public var size: Int64
    /// The time of the copy (Unix milliseconds, from its name).
    public var createdAtMs: Int64
    /// `start`, `upgrade`, `daily`, `manual` or `before-restore`; a newer daemon may send more.
    public var reason: String

    public var id: String { name }

    public var createdAt: Date { Date(timeIntervalSince1970: Double(createdAtMs) / 1000) }
}

/// The reply to `backups.restore`: the daemon answers first, then restarts.
public struct BackupRestoreReply: Codable, Sendable, Hashable {
    public var restarting: Bool
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
        struct P: Encodable { var name: String }
        return try await rpc().call("backups.restore", P(name: name), as: BackupRestoreReply.self).restarting
    }
}
