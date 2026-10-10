import BanditoKit
import CryptoKit
import Foundation
import Testing

@testable import BanditoUI

/// A store that cannot be written: removing a key must fail before anything else happens.
struct FailingStore: SecretStore {
    func load(account: String) throws -> Data? { nil }
    func save(_ data: Data?, account: String) throws {
        throw SecretStoreError.keychain(-1)
    }
}

/// A store that refuses to write one account, and keeps the rest in memory: a parking step that fails.
struct RefusingStore: SecretStore {
    let inner: MemorySecretStore
    let refused: String

    func load(account: String) throws -> Data? {
        try inner.load(account: account)
    }

    func save(_ data: Data?, account: String) throws {
        if account == refused { throw SecretStoreError.keychain(-2) }
        try inner.save(data, account: account)
    }
}

/// A store whose reads fail: the Keychain refuses to say what is stored.
struct UnreadableStore: SecretStore {
    let inner: MemorySecretStore

    func load(account: String) throws -> Data? {
        throw SecretStoreError.keychain(-3)
    }

    func save(_ data: Data?, account: String) throws {
        try inner.save(data, account: account)
    }
}

@MainActor
@Suite struct AccountSafetyTests {
    private func session() -> Session {
        Session(token: "tok_live", user: AccountUser(id: "u", email: nil, name: nil, githubLogin: nil),
                device: DeviceRef(id: "d", approved: true))
    }

    private func filledStore() throws -> MemorySecretStore {
        let store = MemorySecretStore()
        try store.save(Data("key".utf8), account: SyncKey.keychainAccount)
        try store.save(Data("session".utf8), account: AccountClient.sessionAccount)
        return store
    }

    @Test func signOutRemovesTheKeyAndTheSessionEvenWhenTheServerFails() async throws {
        let store = try filledStore()
        var logged: [String] = []
        try await SignOutSteps.run(
            keys: store, session: session(), forgetThisMac: false,
            revoke: { _ in throw AccountError.network("offline") },
            log: { logged.append($0) })
        #expect(try store.load(account: SyncKey.keychainAccount) == nil)
        #expect(try store.load(account: AccountClient.sessionAccount) == nil)
        #expect(logged.count == 1)
    }

    @Test func aServerThatConfirmsTheEndLogsNothing() async throws {
        let store = try filledStore()
        var logged: [String] = []
        var revoked: String?
        try await SignOutSteps.run(
            keys: store, session: session(), forgetThisMac: false,
            revoke: { revoked = $0.token },
            log: { logged.append($0) })
        #expect(revoked == "tok_live")
        #expect(logged.isEmpty)
    }

    @Test func aFailedKeyRemovalStopsBeforeTheServerIsAsked() async throws {
        var asked = false
        await #expect(throws: SecretStoreError.self) {
            try await SignOutSteps.run(
                keys: FailingStore(), session: session(), forgetThisMac: false,
                revoke: { _ in asked = true },
                log: { _ in })
        }
        #expect(asked == false)
    }

    /// A store with a real 256-bit sync key, a session, and optionally a key parked earlier for another account.
    private func storeWithRealKey(parkedFor other: String? = nil) throws -> MemorySecretStore {
        let store = MemorySecretStore()
        try SyncKey.save(SymmetricKey(data: Data(repeating: 5, count: 32)), to: store)
        try store.save(Data("session".utf8), account: AccountClient.sessionAccount)
        if let other {
            try ParkedSyncKey.park(SymmetricKey(data: Data(repeating: 6, count: 32)), accountID: other, in: store)
        }
        return store
    }

    private func noopRevoke(_: Session) async throws {}

    @Test func aPlainSignOutParksTheKeyOfTheAccount() async throws {
        let store = try storeWithRealKey()
        try await SignOutSteps.run(
            keys: store, session: session(), forgetThisMac: false,
            revoke: noopRevoke, log: { _ in })
        #expect(try SyncKey.load(from: store) == nil)
        #expect(try store.load(account: AccountClient.sessionAccount) == nil)
        let parked = try #require(try ParkedSyncKey.loadParked(from: store))
        #expect(parked.accountID == "u")
        #expect(parked.key.withUnsafeBytes { Data($0) } == Data(repeating: 5, count: 32))
    }

    @Test func aPlainSignOutWithoutASessionParksNothing() async throws {
        let store = try storeWithRealKey()
        try await SignOutSteps.run(
            keys: store, session: nil, forgetThisMac: false,
            revoke: noopRevoke, log: { _ in })
        #expect(try SyncKey.load(from: store) == nil)
        #expect(try ParkedSyncKey.loadParked(from: store) == nil)
    }

    @Test func aPlainSignOutWithoutAKeyOnThisMacParksNothing() async throws {
        let store = MemorySecretStore()
        try store.save(Data("session".utf8), account: AccountClient.sessionAccount)
        try await SignOutSteps.run(
            keys: store, session: session(), forgetThisMac: false,
            revoke: noopRevoke, log: { _ in })
        #expect(try ParkedSyncKey.loadParked(from: store) == nil)
    }

    @Test func forgettingTheMacDeletesTheKeyTheParkedKeyAndTheSession() async throws {
        let store = try storeWithRealKey(parkedFor: "other")
        try await SignOutSteps.run(
            keys: store, session: session(), forgetThisMac: true,
            revoke: noopRevoke, log: { _ in })
        #expect(try SyncKey.load(from: store) == nil)
        #expect(try ParkedSyncKey.loadParked(from: store) == nil)
        #expect(try store.load(account: AccountClient.sessionAccount) == nil)
    }

    @Test func aFailedParkingDeletesNothing() async throws {
        let inner = try storeWithRealKey()
        let store = RefusingStore(inner: inner, refused: ParkedSyncKey.keychainAccount)
        var asked = false
        await #expect(throws: SecretStoreError.self) {
            try await SignOutSteps.run(
                keys: store, session: session(), forgetThisMac: false,
                revoke: { _ in asked = true }, log: { _ in })
        }
        #expect(try SyncKey.load(from: inner) != nil)
        #expect(try inner.load(account: AccountClient.sessionAccount) != nil)
        #expect(asked == false)
    }

    @Test func aKeyThatCannotBeReadStopsTheSignOutBeforeAnythingIsDeleted() async throws {
        let inner = try storeWithRealKey(parkedFor: "other")
        var asked = false
        await #expect(throws: SecretStoreError.self) {
            try await SignOutSteps.run(
                keys: UnreadableStore(inner: inner), session: session(), forgetThisMac: false,
                revoke: { _ in asked = true }, log: { _ in })
        }
        #expect(try SyncKey.load(from: inner) != nil)
        #expect(try inner.load(account: AccountClient.sessionAccount) != nil)
        #expect(asked == false)
    }

    @Test func aDamagedKeyIsSignedOutWithoutBeingParked() async throws {
        let store = try filledStore()
        try await SignOutSteps.run(
            keys: store, session: session(), forgetThisMac: false,
            revoke: { _ in }, log: { _ in })
        #expect(try store.load(account: SyncKey.keychainAccount) == nil)
        #expect(try ParkedSyncKey.loadParked(from: store) == nil)
    }

    @Test func forgettingClearsTheParkedKeyBeforeTheLiveKey() async throws {
        let inner = try storeWithRealKey(parkedFor: "other")
        let store = RefusingStore(inner: inner, refused: SyncKey.keychainAccount)
        await #expect(throws: SecretStoreError.self) {
            try await SignOutSteps.run(
                keys: store, session: session(), forgetThisMac: true,
                revoke: { _ in }, log: { _ in })
        }
        #expect(try ParkedSyncKey.loadParked(from: inner) == nil)
        #expect(try SyncKey.load(from: inner) != nil)
    }

    @Test func publishingRetriesAfterAConflict() async throws {
        var writes = 0
        _ = try await ServerPublishing.publish(
            local: SyncPayload(), fetch: { nil },
            write: { payload in
                writes += 1
                if writes < 3 { throw AccountError.conflict(current: writes) }
                return payload
            })
        #expect(writes == 3)
    }

    @Test func publishingGivesUpAfterThreeConflicts() async throws {
        var writes = 0
        await #expect(throws: AccountError.conflict(current: 9)) {
            _ = try await ServerPublishing.publish(
                local: SyncPayload(), fetch: { nil },
                write: { _ in
                    writes += 1
                    throw AccountError.conflict(current: 9)
                })
        }
        #expect(writes == 3)
    }

    @Test func mergeKeepsTheRemoteServersAndReplacesTheSameId() {
        let shared = UUID()
        let remoteOnly = UUID()
        let local = SyncPayload(servers: [
            SyncedServer(id: shared, name: "new name", endpoint: .ssh(host: "a.example", user: nil, port: nil), addedAt: 2),
        ])
        let remote = SyncPayload(servers: [
            SyncedServer(id: shared, name: "old name", endpoint: .ssh(host: "a.example", user: nil, port: nil), addedAt: 1),
            SyncedServer(id: remoteOnly, name: "other", endpoint: .ssh(host: "b.example", user: nil, port: nil), addedAt: 1),
        ])
        let merged = ServerSyncPayload.merge(local: local, remote: remote)
        #expect(merged.servers.map(\.name) == ["new name", "other"])
    }
}
