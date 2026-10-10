import CryptoKit
import Foundation
import Observation

public enum SyncStoreError: Error, Equatable, Sendable {
    /// The account has data, but this device has no sync key. It must be approved first.
    case keyMissing
    /// The stored payload was written by a newer app. Its version is attached.
    case newerVersion(Int)
    /// The server offered blob version `got`, older than `seen`: the newest version this device has read.
    /// The blob is not applied.
    case rollback(seen: Int, got: Int)
}

/// Pulls and pushes the account's `SyncPayload` as one encrypted blob.
///
/// Each blob is bound to its account and version (`SyncKey.blobAssociatedData`). This device remembers the
/// newest version it has read per account (`sync.maxSeenVersion.<accountID>` in `defaults`), and refuses an
/// older one: a server cannot replay a stale blob.
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
    private let defaults: UserDefaults

    /// - Parameters:
    ///   - keys: the store holding the sync key (the app's account store).
    ///   - defaults: where the newest seen version per account is kept. Tests pass a private suite.
    public init(account: AccountClient, keys: SecretStore, defaults: UserDefaults = .standard) {
        self.account = account
        self.keys = keys
        self.defaults = defaults
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

    /// Resets the signed-in account on the server and forgets this device's version history for it. This is the
    /// only supported way to reset: the UI must not call `AccountClient.reset()` itself. The server then starts a
    /// new blob history at version 1, and the old high-water mark would refuse it as a rollback.
    /// If the server refuses the reset, the history is kept.
    public func resetAccount() async throws -> DeviceRef {
        let accountID = try await currentAccountID()
        let device = try await account.reset()
        defaults.removeObject(forKey: Self.versionKey(accountID: accountID))
        knownVersion = 0
        return device
    }

    /// Forgets the newest version this device has read, for the signed-in account. Only `resetAccount` calls it.
    func forgetVersionHistory() async throws {
        defaults.removeObject(forKey: Self.versionKey(accountID: try await currentAccountID()))
        knownVersion = 0
    }

    /// Joins two copies of the payload. Servers are matched by `id`: the local copy wins for an id both
    /// have, and ids only one side has are kept. The local keymap wins when there is one.
    /// The profile is the copy with the newer `updatedAt`; a tie keeps the local one.
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
            snippets: local.snippets ?? remote.snippets,
            profile: SyncedProfile.newer(local.profile, remote.profile))
    }

    static func versionKey(accountID: String) -> String {
        "sync.maxSeenVersion.\(accountID)"
    }

    private func currentAccountID() async throws -> String {
        guard let session = try await account.restoreSession() else { throw AccountError.notSignedIn }
        return session.user.id
    }

    private func maxSeenVersion(accountID: String) -> Int {
        defaults.integer(forKey: Self.versionKey(accountID: accountID))
    }

    private func remember(version: Int, accountID: String) {
        if version > maxSeenVersion(accountID: accountID) {
            defaults.set(version, forKey: Self.versionKey(accountID: accountID))
        }
    }

    private func fetch() async throws -> SyncPayload? {
        let accountID = try await currentAccountID()
        guard let blob = try await account.getSync() else {
            knownVersion = 0
            return nil
        }
        let seen = maxSeenVersion(accountID: accountID)
        guard blob.version >= seen else {
            throw SyncStoreError.rollback(seen: seen, got: blob.version)
        }
        guard let key = try SyncKey.load(from: keys) else { throw SyncStoreError.keyMissing }
        let associatedData = SyncKey.blobAssociatedData(accountID: accountID, version: blob.version)
        let payload = try JSONDecoder().decode(
            SyncPayload.self, from: try SyncKey.openBlob(blob.blob, key: key, associatedData: associatedData))
        guard payload.version <= SyncPayload.currentVersion else {
            throw SyncStoreError.newerVersion(payload.version)
        }
        knownVersion = blob.version
        remember(version: blob.version, accountID: accountID)
        return payload
    }

    private func write(_ payload: SyncPayload) async throws -> SyncPayload {
        let accountID = try await currentAccountID()
        let key: SymmetricKey
        if let existing = try SyncKey.load(from: keys) {
            key = existing
        } else {
            // A new key is only safe when the account has no blob: it could not open the existing one.
            guard try await account.getSync() == nil else { throw SyncStoreError.keyMissing }
            key = try SyncKey.loadOrCreate(from: keys)
        }
        // The server stores the blob at knownVersion + 1 when the expected version matches, so the
        // version is known before the request. The blob is bound to it.
        let version = knownVersion + 1
        let associatedData = SyncKey.blobAssociatedData(accountID: accountID, version: version)
        let blob = try SyncKey.sealBlob(
            try JSONEncoder().encode(payload), key: key, associatedData: associatedData)
        let stored = try await account.putSync(version: knownVersion, blob: blob)
        guard stored == version else { throw AccountError.badResponse }
        knownVersion = stored
        remember(version: stored, accountID: accountID)
        return payload
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
