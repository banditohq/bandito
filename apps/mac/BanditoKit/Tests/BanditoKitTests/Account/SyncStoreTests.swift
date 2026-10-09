import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@MainActor
@Suite struct SyncStoreTests {
    private let serverA = SyncedServer(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
        name: "vps-a",
        endpoint: .ssh(host: "a.example.com", user: "deploy", port: nil),
        addedAt: 1_000)
    private let serverB = SyncedServer(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
        name: "vps-b",
        endpoint: .local(deviceID: "dev-1"),
        addedAt: 2_000)

    private let accountID = "u1"

    /// A store wired to scripted HTTP, signed in, with the given sync key store and a private defaults suite.
    private func makeStore(
        http: ScriptedHTTP, keys: MemorySecretStore, defaults: UserDefaults = SyncStoreTests.freshDefaults()
    ) throws -> SyncStore {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let client = try makeClient(http: http, sessions: sessions)
        return SyncStore(account: client, keys: keys, defaults: defaults)
    }

    /// The encrypted blob of `payload` stored at `version`, as another device would store it.
    private func blob(of payload: SyncPayload, key: SymmetricKey, version: Int) throws -> String {
        try SyncKey.sealBlob(
            JSONEncoder().encode(payload), key: key,
            associatedData: SyncKey.blobAssociatedData(accountID: accountID, version: version))
    }

    /// The payload a PUT stored. The PUT names the version it expects; the blob lands one version higher.
    private func payload(in request: URLRequest, key: SymmetricKey) throws -> SyncPayload {
        let body = try jsonBody(request)
        let sealed = try #require(body["blob"] as? String)
        let expected = try #require(body["version"] as? Int)
        return try JSONDecoder().decode(
            SyncPayload.self,
            from: try SyncKey.openBlob(
                sealed, key: key,
                associatedData: SyncKey.blobAssociatedData(accountID: accountID, version: expected + 1)))
    }

    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sync-store-tests-\(UUID().uuidString)")!
    }

    @Test func pullReturnsNilWhenTheAccountHasNoBlob() async throws {
        let http = ScriptedHTTP([
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":0,"blob":null}"#)]
        ])
        let store = try makeStore(http: http, keys: MemorySecretStore())

        #expect(try await store.pull() == nil)
        #expect(store.knownVersion == 0)
        #expect(store.state == .idle)
    }

    @Test func firstPushOnAFreshAccountCreatesTheKeyAndWritesVersionOne() async throws {
        let keys = MemorySecretStore()
        let http = ScriptedHTTP([
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":0,"blob":null}"#)],
            "PUT /sync": [ScriptedReply(#"{"ok":true,"version":1}"#)],
        ])
        let store = try makeStore(http: http, keys: keys)
        let local = SyncPayload(servers: [serverA])

        let stored = try await store.push(local)

        #expect(stored == local)
        #expect(store.knownVersion == 1)
        #expect(store.state == .idle)
        let key = try #require(try SyncKey.load(from: keys))
        let put = try #require(http.requests.last)
        #expect(try jsonBody(put)["version"] as? Int == 0)
        #expect(try payload(in: put, key: key) == local)
        #expect(store.knownVersion == 1)
    }

    @Test func pullDecryptsThePayloadAnotherDeviceWrote() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        let remote = SyncPayload(servers: [serverA, serverB], keymap: Data("{}".utf8))
        let http = ScriptedHTTP([
            "GET /sync": [
                ScriptedReply(#"{"ok":true,"version":3,"blob":"\#(try blob(of: remote, key: key, version: 3))"}"#)
            ]
        ])
        let store = try makeStore(http: http, keys: keys)

        #expect(try await store.pull() == remote)
        #expect(store.knownVersion == 3)
    }

    @Test func pushWithoutTheKeyWhenTheAccountHasDataIsKeyMissingAndWritesNothing() async throws {
        let otherKey = SymmetricKey(size: .bits256)
        let existing = try blob(of: SyncPayload(servers: [serverA]), key: otherKey, version: 2)
        let http = ScriptedHTTP([
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":2,"blob":"\#(existing)"}"#)]
        ])
        let store = try makeStore(http: http, keys: MemorySecretStore())

        do {
            _ = try await store.push(SyncPayload(servers: [serverB]))
            Issue.record("expected keyMissing")
        } catch let error as SyncStoreError {
            #expect(error == .keyMissing)
        }
        #expect(!http.keys.contains { $0.hasPrefix("PUT") })
        #expect(store.state != .idle)
    }

    @Test func conflictPullsMergesAndWritesOnce() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        let remote = try blob(of: SyncPayload(servers: [serverA]), key: key, version: 5)
        let http = ScriptedHTTP([
            "PUT /sync": [
                ScriptedReply(#"{"ok":false,"error":"conflict","version":5}"#, status: 409),
                ScriptedReply(#"{"ok":true,"version":6}"#),
            ],
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":5,"blob":"\#(remote)"}"#)],
        ])
        let store = try makeStore(http: http, keys: keys)

        let stored = try await store.push(SyncPayload(servers: [serverB]))

        #expect(http.keys == ["PUT /sync", "GET /sync", "PUT /sync"])
        let retry = try #require(http.requests.last)
        #expect(try jsonBody(retry)["version"] as? Int == 5)
        #expect(try payload(in: retry, key: key).servers.map(\.id) == [serverA.id, serverB.id])
        #expect(stored.servers.map(\.id) == [serverA.id, serverB.id])
        #expect(store.knownVersion == 6)
        #expect(store.state == .idle)
    }

    @Test func secondConflictGivesUpAfterOneRetry() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        let remote = try blob(of: SyncPayload(servers: [serverA]), key: key, version: 5)
        let http = ScriptedHTTP([
            "PUT /sync": [
                ScriptedReply(#"{"ok":false,"error":"conflict","version":5}"#, status: 409),
                ScriptedReply(#"{"ok":false,"error":"conflict","version":6}"#, status: 409),
            ],
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":5,"blob":"\#(remote)"}"#)],
        ])
        let store = try makeStore(http: http, keys: keys)

        do {
            _ = try await store.push(SyncPayload(servers: [serverB]))
            Issue.record("expected conflict after one retry")
        } catch let error as AccountError {
            #expect(error == .conflict(current: 6))
        }
        #expect(http.keys.filter { $0 == "PUT /sync" }.count == 2)
        if case .error = store.state {} else { Issue.record("expected the error state") }
    }

    @Test func mergeKeepsTheLocalCopyOfAServerAndAddsTheRest() {
        let renamed = SyncedServer(id: serverA.id, name: "vps-a-renamed", endpoint: serverA.endpoint, addedAt: 1_000)
        let serverC = SyncedServer(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
            name: "vps-c",
            endpoint: .webSocket(url: URL(string: "wss://c.example.com/v1/rpc")!),
            addedAt: 3_000)
        let local = SyncPayload(servers: [renamed, serverB])
        let remote = SyncPayload(servers: [serverA, serverC], keymap: Data([1]))

        let merged = SyncStore.merge(local: local, remote: remote)

        #expect(merged.servers.map(\.name) == ["vps-a-renamed", "vps-c", "vps-b"])
        // No local keymap: the remote one is kept.
        #expect(merged.keymap == Data([1]))
    }

    @Test func aBlobOlderThanTheNewestVersionThisDeviceSawIsARollback() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        let defaults = Self.freshDefaults()
        defaults.set(5, forKey: SyncStore.versionKey(accountID: accountID))
        let old = try blob(of: SyncPayload(servers: [serverA]), key: key, version: 2)
        let http = ScriptedHTTP([
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":2,"blob":"\#(old)"}"#)]
        ])
        let store = try makeStore(http: http, keys: keys, defaults: defaults)

        do {
            _ = try await store.pull()
            Issue.record("expected rollback")
        } catch let error as SyncStoreError {
            #expect(error == .rollback(seen: 5, got: 2))
        }
        #expect(store.knownVersion == 0)
        if case .error = store.state {} else { Issue.record("expected the error state") }
    }

    @Test func aBlobAtTheNewestVersionIsAccepted() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        let defaults = Self.freshDefaults()
        defaults.set(5, forKey: SyncStore.versionKey(accountID: accountID))
        let current = SyncPayload(servers: [serverB])
        let http = ScriptedHTTP([
            "GET /sync": [
                ScriptedReply(#"{"ok":true,"version":5,"blob":"\#(try blob(of: current, key: key, version: 5))"}"#)
            ]
        ])
        let store = try makeStore(http: http, keys: keys, defaults: defaults)

        #expect(try await store.pull() == current)
        #expect(store.knownVersion == 5)
    }

    @Test func pullAndPushRecordTheNewestVersionSeen() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        let defaults = Self.freshDefaults()
        let http = ScriptedHTTP([
            "GET /sync": [
                ScriptedReply(#"{"ok":true,"version":3,"blob":"\#(try blob(of: SyncPayload(), key: key, version: 3))"}"#)
            ],
            "PUT /sync": [ScriptedReply(#"{"ok":true,"version":4}"#)],
        ])
        let store = try makeStore(http: http, keys: keys, defaults: defaults)

        try await store.pull()
        #expect(defaults.integer(forKey: SyncStore.versionKey(accountID: accountID)) == 3)
        try await store.push(SyncPayload(servers: [serverA]))
        #expect(defaults.integer(forKey: SyncStore.versionKey(accountID: accountID)) == 4)
    }

    @Test func aBlobLabelledWithAnotherVersionDoesNotOpen() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        // Sealed for version 3, but the server says it is version 4.
        let relabelled = try blob(of: SyncPayload(servers: [serverA]), key: key, version: 3)
        let http = ScriptedHTTP([
            "GET /sync": [ScriptedReply(#"{"ok":true,"version":4,"blob":"\#(relabelled)"}"#)]
        ])
        let store = try makeStore(http: http, keys: keys)

        do {
            _ = try await store.pull()
            Issue.record("expected cannotOpen")
        } catch let error as SyncKeyError {
            #expect(error == .cannotOpen)
        }
    }

    @Test func forgettingTheVersionHistoryAllowsANewLineageAfterAReset() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        let defaults = Self.freshDefaults()
        defaults.set(5, forKey: SyncStore.versionKey(accountID: accountID))
        let fresh = SyncPayload(servers: [serverB])
        let http = ScriptedHTTP([
            "GET /sync": [
                ScriptedReply(#"{"ok":true,"version":1,"blob":"\#(try blob(of: fresh, key: key, version: 1))"}"#)
            ]
        ])
        let store = try makeStore(http: http, keys: keys, defaults: defaults)

        try await store.forgetVersionHistory()

        #expect(try await store.pull() == fresh)
        #expect(defaults.integer(forKey: SyncStore.versionKey(accountID: accountID)) == 1)
    }
}
