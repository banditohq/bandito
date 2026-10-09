import CryptoKit
import Foundation
import Observation

public enum SyncStoreError: Error, Equatable, Sendable {
    /// The account has data, but this device has no sync key. It must be approved first.
    case keyMissing
    /// The stored payload was written by a newer app. Its version is attached.
    case newerVersion(Int)
}

/// Pulls and pushes the account's `SyncPayload` as one encrypted blob.
@MainActor
@Observable
public final class SyncStore {
    public enum State: Sendable, Equatable {
        case idle
        case syncing
        case error(String)
    }

    public private(set) var state: State = .idle
    /// The blob version this device last read or wrote. 0 when the account has none.
    public private(set) var knownVersion = 0

    private let account: AccountClient
    private let keys: SecretStore

    /// - Parameter keys: the store holding the sync key (the app's account store).
    public init(account: AccountClient, keys: SecretStore) {
        self.account = account
        self.keys = keys
    }

    /// Fetches and decrypts the account's payload. Nil when the account has no data yet.
    @discardableResult
    public func pull() async throws -> SyncPayload? {
        state = .syncing
        do {
            let payload = try await fetch()
            state = .idle
            return payload
        } catch {
            state = .error(Self.message(for: error))
            throw error
        }
    }

    /// Encrypts and stores `payload`, and returns what was stored.
    ///
    /// Optimistic: writes at the version this device knows. On a conflict it pulls the newer blob, merges
    /// it with `payload` (see `merge`), and writes once more. A second conflict is thrown.
    @discardableResult
    public func push(_ payload: SyncPayload) async throws -> SyncPayload {
        state = .syncing
        do {
            let stored: SyncPayload
            do {
                stored = try await write(payload)
            } catch AccountError.conflict(_) {
                let remote = try await fetch() ?? SyncPayload()
                stored = try await write(Self.merge(local: payload, remote: remote))
            }
            state = .idle
            return stored
        } catch {
            state = .error(Self.message(for: error))
            throw error
        }
    }

    /// Joins two copies of the payload. Servers are matched by `id`: the local copy wins for an id both
    /// have, and ids only one side has are kept. The local keymap wins when there is one.
    /// There are no tombstones, so a server deleted on one device comes back if another device
    /// still has it and pushes.
    static func merge(local: SyncPayload, remote: SyncPayload) -> SyncPayload {
        var servers = remote.servers
        for server in local.servers {
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index] = server
            } else {
                servers.append(server)
            }
        }
        return SyncPayload(
            version: SyncPayload.currentVersion,
            servers: servers,
            keymap: local.keymap ?? remote.keymap,
            snippets: local.snippets ?? remote.snippets)
    }

    private func fetch() async throws -> SyncPayload? {
        guard let blob = try await account.getSync() else {
            knownVersion = 0
            return nil
        }
        guard let key = try SyncKey.load(from: keys) else { throw SyncStoreError.keyMissing }
        let payload = try JSONDecoder().decode(
            SyncPayload.self, from: try SyncKey.openBlob(blob.blob, key: key))
        guard payload.version <= SyncPayload.currentVersion else {
            throw SyncStoreError.newerVersion(payload.version)
        }
        knownVersion = blob.version
        return payload
    }

    private func write(_ payload: SyncPayload) async throws -> SyncPayload {
        let key: SymmetricKey
        if let existing = try SyncKey.load(from: keys) {
            key = existing
        } else {
            // A new key is only safe when the account has no blob: it could not open the existing one.
            guard try await account.getSync() == nil else { throw SyncStoreError.keyMissing }
            key = try SyncKey.loadOrCreate(from: keys)
        }
        let blob = try SyncKey.sealBlob(try JSONEncoder().encode(payload), key: key)
        knownVersion = try await account.putSync(version: knownVersion, blob: blob)
        return payload
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
