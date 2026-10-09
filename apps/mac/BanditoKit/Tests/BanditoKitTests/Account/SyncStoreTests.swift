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

    /// A store wired to scripted HTTP, signed in, with the given sync key store.
    private func makeStore(http: ScriptedHTTP, keys: MemorySecretStore) throws -> SyncStore {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let client = try makeClient(http: http, sessions: sessions)
        return SyncStore(account: client, keys: keys)
    }

    /// The encrypted blob of `payload`, as another device would store it.
    private func blob(of payload: SyncPayload, key: SymmetricKey) throws -> String {
        try SyncKey.sealBlob(JSONEncoder().encode(payload), key: key)
    }

    private func payload(in request: URLRequest, key: SymmetricKey) throws -> SyncPayload {
        let body = try jsonBody(request)
        let sealed = try #require(body["blob"] as? String)
        return try JSONDecoder().decode(SyncPayload.self, from: try SyncKey.openBlob(sealed, key: key))
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
    }

    @Test func pullDecryptsThePayloadAnotherDeviceWrote() async throws {
        let keys = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)
        try SyncKey.save(key, to: keys)
        let remote = SyncPayload(servers: [serverA, serverB], keymap: Data("{}".utf8))
        let http = ScriptedHTTP([
            "GET /sync": [
                ScriptedReply(#"{"ok":true,"version":3,"blob":"\#(try blob(of: remote, key: key))"}"#)
            ]
        ])
        let store = try makeStore(http: http, keys: keys)

        #expect(try await store.pull() == remote)
        #expect(store.knownVersion == 3)
    }

    @Test func pushWithoutTheKeyWhenTheAccountHasDataIsKeyMissingAndWritesNothing() async throws {
        let otherKey = SymmetricKey(size: .bits256)
        let existing = try blob(of: SyncPayload(servers: [serverA]), key: otherKey)
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
        let remote = try blob(of: SyncPayload(servers: [serverA]), key: key)
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
        let remote = try blob(of: SyncPayload(servers: [serverA]), key: key)
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
}
