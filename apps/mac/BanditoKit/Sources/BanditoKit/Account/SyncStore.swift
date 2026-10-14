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

    /// How many times a write is tried when the version moved on under it.
    public static let maxAttempts = 5
    /// A conflict that outlasts this many seconds is no longer treated as passing: it is shown to the person.
    public static let persistentConflictAfter: TimeInterval = 120

    private let account: AccountClient
    private let keys: SecretStore
    private let defaults: UserDefaults
    private let pause: @MainActor () async throws -> Void
    private let now: () -> Date
    /// When the writes started to fail with a conflict without a single success in between. Nil while they succeed.
    private var conflictingSince: Date?

    /// - Parameters:
    ///   - keys: the store holding the sync key (the app's account store).
    ///   - defaults: where the newest seen version per account is kept. Tests pass a private suite.
    ///   - pause: the wait between two attempts of a write. Default: a random 100 to 800 ms, so two devices that collided
    ///     do not collide again in step. Tests pass a no-op.
    ///   - now: the clock, for the "conflict lasts more than two minutes" rule.
    public init(
        account: AccountClient, keys: SecretStore, defaults: UserDefaults = .standard,
        pause: @escaping @MainActor () async throws -> Void = SyncStore.randomPause,
        now: @escaping () -> Date = Date.init
    ) {
        self.account = account
        self.keys = keys
        self.defaults = defaults
        self.pause = pause
        self.now = now
    }

    /// The default wait between two attempts: 100 to 800 ms, random.
    @MainActor public static func randomPause() async throws {
        try await Task.sleep(for: .milliseconds(Int.random(in: 100...800)))
    }

    /// True when writes have lost to other devices for more than two minutes in a row. Only then is a conflict an error
    /// for the person; before that it is quietly left for the next round.
    public var hasPersistentConflict: Bool {
        guard let since = conflictingSince else { return false }
        return now().timeIntervalSince(since) > Self.persistentConflictAfter
    }

    /// Whether `error` is a version conflict that may stay unseen: the write is tried again by the next round.
    public func isQuietConflict(_ error: Error) -> Bool {
        if case AccountError.conflict = error { return !hasPersistentConflict }
        return false
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

    /// Merges `payload` into the newest copy and stores the result, and returns what was stored. A shortcut for
    /// `update` with `merge`: the same read-merge-write path with retries.
    @discardableResult
    public func push(_ payload: SyncPayload) async throws -> SyncPayload {
        try await update { remote in remote = Self.merge(local: payload, remote: remote) }
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

    /// Joins two copies of the payload: see `SyncPayload.merged`. Servers are matched by `id` (the local copy wins),
    /// the profile is the newer copy, requests and grants are the newest per device and server and are dropped after
    /// a week, and fields this build does not know are kept.
    /// There are no tombstones, so a server deleted on one device comes back if another device
    /// still has it and pushes.
    static func merge(local: SyncPayload, remote: SyncPayload, now: Date = Date()) -> SyncPayload {
        SyncPayload.merged(local: local, remote: remote, now: now)
    }

    /// The one way to write the blob. Reads the newest payload (an account with no blob starts from an empty one), lets
    /// `mutate` change it, and writes the result at the version just read. When the version moved on (HTTP 409) the
    /// payload is read again and `mutate` runs again on it, up to `maxAttempts` times with a short random pause: a change
    /// such as removing an answered request is applied to the newest copy, so nothing another device wrote is lost and
    /// a removed entry does not come back. A change that leaves the payload as it was writes nothing.
    ///
    /// If every attempt loses, `AccountError.conflict` is thrown, but `state` stays out of `.error` until the conflict has
    /// lasted two minutes (`hasPersistentConflict`): callers leave the write to their next round (`isQuietConflict`).
    @discardableResult
    public func update(_ mutate: (inout SyncPayload) -> Void) async throws -> SyncPayload {
        state = .syncing
        var lastConflict = 0
        for attempt in 1...Self.maxAttempts {
            do {
                let fetched = try await fetch()
                var payload = fetched ?? SyncPayload()
                mutate(&payload)
                let stored: SyncPayload
                if let fetched, fetched == payload {
                    stored = payload
                } else {
                    stored = try await write(payload)
                }
                conflictingSince = nil
                state = .idle
                return stored
            } catch AccountError.conflict(let current) {
                lastConflict = current
                if attempt < Self.maxAttempts {
                    do { try await pause() } catch {
                        state = .idle
                        throw error
                    }
                }
            } catch {
                state = error is CancellationError ? .idle : .error(Self.message(for: error))
                throw error
            }
        }
        if conflictingSince == nil { conflictingSince = now() }
        let failure = AccountError.conflict(current: lastConflict)
        state = hasPersistentConflict ? .error(Self.message(for: failure)) : .idle
        throw failure
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
        let head = try await account.syncHead()
        let seen = maxSeenVersion(accountID: accountID)
        guard head.version >= seen else {
            throw SyncStoreError.rollback(seen: seen, got: head.version)
        }
        // No blob, but the version may be above 0 (it never goes back after a reset): the next write names it.
        guard let blob = head.blob else {
            knownVersion = head.version
            remember(version: head.version, accountID: accountID)
            return nil
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
