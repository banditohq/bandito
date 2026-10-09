import BanditoKit
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
            keys: store, session: session(),
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
            keys: store, session: session(),
            revoke: { revoked = $0.token },
            log: { logged.append($0) })
        #expect(revoked == "tok_live")
        #expect(logged.isEmpty)
    }

    @Test func aFailedKeyRemovalStopsBeforeTheServerIsAsked() async throws {
        var asked = false
        await #expect(throws: SecretStoreError.self) {
            try await SignOutSteps.run(
                keys: FailingStore(), session: session(),
                revoke: { _ in asked = true },
                log: { _ in })
        }
        #expect(asked == false)
    }

    @Test func publishingRetriesAfterAConflict() async throws {
        var writes = 0
        try await ServerPublishing.publish(
            local: SyncPayload(), fetch: { nil },
            write: { _ in
                writes += 1
                if writes < 3 { throw AccountError.conflict(current: writes) }
            })
        #expect(writes == 3)
    }

    @Test func publishingGivesUpAfterThreeConflicts() async throws {
        var writes = 0
        await #expect(throws: AccountError.conflict(current: 9)) {
            try await ServerPublishing.publish(
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
