import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

/// An in-memory account service for the blob: it keeps a version and a ciphertext, as `docs/ACCOUNTS_API.md` says
/// (`PUT` at the stored version or `409 conflict`; the version survives a reset). `beforePut` runs ahead of each PUT, so a
/// test can make another device write between this device's GET and PUT.
private final class FakeSyncServer: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var version: Int
    private var blob: String?
    private var puts = 0
    var beforePut: (@Sendable (FakeSyncServer, Int) -> Void)?

    init(version: Int = 0, blob: String? = nil) {
        self.version = version
        self.blob = blob
    }

    var putCount: Int { lock.withLock { puts } }
    var current: (version: Int, blob: String?) { lock.withLock { (version, blob) } }

    /// Another device stores `blob` at the next version.
    func storeFromAnotherDevice(_ blob: String) {
        lock.withLock {
            version += 1
            self.blob = blob
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Let other tasks run between a device's requests, so two devices interleave.
        await Task.yield()
        let url = try #require(request.url)
        func reply(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        guard url.path.hasSuffix("/sync") else { throw URLError(.cannotConnectToHost) }
        if request.httpMethod == "GET" {
            let (v, b) = current
            return reply(200, #"{"ok":true,"version":\#(v),"blob":\#(b.map { "\"\($0)\"" } ?? "null")}"#)
        }
        let n = lock.withLock { () -> Int in
            puts += 1
            return puts
        }
        beforePut?(self, n)
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any] ?? [:]
        let expected = body["version"] as? Int ?? -1
        let sealed = body["blob"] as? String
        return lock.withLock {
            guard expected == version else {
                return reply(409, #"{"ok":false,"error":"conflict","version":\#(version)}"#)
            }
            version += 1
            blob = sealed
            return reply(200, #"{"ok":true,"version":\#(version)}"#)
        }
    }
}

@MainActor
@Suite struct SyncConflictTests {
    private let accountID = "u1"
    private let key = SymmetricKey(size: .bits256)

    nonisolated private func server(_ n: UInt8) -> SyncedServer {
        SyncedServer(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02X", n))")!,
            name: "vps-\(n)", endpoint: .local(deviceID: "dev-\(n)"), addedAt: Int64(n))
    }

    nonisolated private func seal(_ payload: SyncPayload, version: Int) throws -> String {
        try SyncKey.sealBlob(
            JSONEncoder().encode(payload), key: key,
            associatedData: SyncKey.blobAssociatedData(accountID: accountID, version: version))
    }

    nonisolated private func open(_ blob: String, version: Int) throws -> SyncPayload {
        try JSONDecoder().decode(
            SyncPayload.self,
            from: try SyncKey.openBlob(
                blob, key: key, associatedData: SyncKey.blobAssociatedData(accountID: accountID, version: version)))
    }

    private func makeStore(_ http: FakeSyncServer, now: @escaping () -> Date = Date.init) throws -> SyncStore {
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok")
        let keys = MemorySecretStore()
        try SyncKey.save(key, to: keys)
        let client = try AccountClient(
            identity: try makeIdentity(), sessions: sessions, http: http,
            device: DeviceDescriptor(name: "Test", platform: "macos"), retryDelay: .zero)
        return SyncStore(
            account: client, keys: keys, defaults: UserDefaults(suiteName: "sync-conflict-\(UUID().uuidString)")!,
            pause: {}, now: now)
    }

    @Test func writePassesAfterTwoConflictsAndKeepsBothEdits() async throws {
        let http = FakeSyncServer(version: 1, blob: try seal(SyncPayload(servers: [server(1)]), version: 1))
        // Another device writes between this device's GET and PUT, the first two times.
        http.beforePut = { [self] fake, n in
            guard n <= 2 else { return }
            let other = SyncPayload(servers: [server(1)] + (11...UInt8(10 + n)).map { server($0) })
            let next = fake.current.version + 1
            fake.storeFromAnotherDevice((try? seal(other, version: next)) ?? "")
        }
        let store = try makeStore(http)

        try await store.update { $0.servers.append(server(2)) }

        #expect(http.putCount == 3)
        let (version, blob) = http.current
        let stored = try open(try #require(blob), version: version)
        #expect(Set(stored.servers.map(\.name)) == ["vps-1", "vps-2", "vps-11", "vps-12"])
        #expect(store.state == .idle)
        #expect(!store.hasPersistentConflict)
    }

    @Test func aConflictThatNeverClearsIsQuietAtFirstAndShownAfterTwoMinutes() async throws {
        let http = FakeSyncServer(version: 1, blob: try seal(SyncPayload(servers: [server(1)]), version: 1))
        http.beforePut = { [self] fake, n in
            let next = fake.current.version + 1
            fake.storeFromAnotherDevice((try? seal(SyncPayload(servers: [server(1)]), version: next)) ?? "")
        }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = try makeStore(http, now: { clock })

        await #expect(throws: AccountError.self) { try await store.update { $0.servers.append(server(2)) } }
        #expect(http.putCount == SyncStore.maxAttempts)
        #expect(store.state == .idle)
        #expect(!store.hasPersistentConflict)

        // The next round: still losing, but not for long enough.
        clock = clock.addingTimeInterval(60)
        do { try await store.update { $0.servers.append(server(2)) } } catch {
            #expect(store.isQuietConflict(error))
        }
        #expect(store.state == .idle)

        // More than two minutes after the first failure: the person is told.
        clock = clock.addingTimeInterval(90)
        do {
            try await store.update { $0.servers.append(server(2)) }
            Issue.record("expected a conflict")
        } catch {
            #expect(!store.isQuietConflict(error))
        }
        if case .error = store.state {} else { Issue.record("expected the error state") }

        // One success clears it.
        http.beforePut = nil
        try await store.update { $0.servers.append(server(2)) }
        #expect(!store.hasPersistentConflict)
        #expect(store.state == .idle)
    }

    @Test func aResetAccountKeepsItsVersionSoTheFirstWriteNamesIt() async throws {
        // After a reset the blob is null but the version stays: writing at version 0 would conflict for ever.
        let http = FakeSyncServer(version: 7, blob: nil)
        let store = try makeStore(http)

        try await store.push(SyncPayload())

        #expect(http.putCount == 1)
        #expect(http.current.version == 8)
        #expect(store.knownVersion == 8)
    }

    @Test func aMacAndAnIPhoneWritingAtOnceKeepBothChanges() async throws {
        let http = FakeSyncServer(version: 1, blob: try seal(SyncPayload(servers: [server(1)]), version: 1))
        let mac = try makeStore(http)
        let phone = try makeStore(http)

        async let a: Void = { try await mac.update { $0.servers.append(server(2)) } }()
        async let b: Void = { try await phone.update { $0.accessRequests.append(AccessRequest(deviceID: "phone", serverID: server(1).id.uuidString, noiseKey: "k", at: 5)) } }()
        _ = try await (a, b)

        let (version, blob) = http.current
        let stored = try open(try #require(blob), version: version)
        #expect(Set(stored.servers.map(\.name)) == ["vps-1", "vps-2"])
        #expect(stored.accessRequests.map(\.deviceID) == ["phone"])
    }

    @Test func aWriteThatChangesNothingSendsNothing() async throws {
        let http = FakeSyncServer(version: 1, blob: try seal(SyncPayload(servers: [server(1)]), version: 1))
        let store = try makeStore(http)

        try await store.update { _ in }

        #expect(http.putCount == 0)
    }
}
