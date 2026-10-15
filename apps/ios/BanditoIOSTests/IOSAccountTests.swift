import BanditoKit
import CryptoKit
import Foundation
import Testing

@testable import Bandito

/// An account server in memory: it answers by `METHOD /path` and records what it was asked.
private final class FakeAccountServer: HTTPClient, @unchecked Sendable {
    // @unchecked: every field is guarded by `lock`.
    private let lock = NSLock()
    private var routes: [String: (status: Int, body: String)] = [:]
    private var recorded: [(key: String, body: Data?)] = []

    private var later: [String: (trigger: String, status: Int, body: String)] = [:]

    func set(_ key: String, _ body: String, status: Int = 200) {
        lock.withLock { routes[key] = (status, body) }
    }

    /// From the first request to `trigger` on, `key` answers with `body`.
    func set(_ key: String, after trigger: String, _ body: String, status: Int = 200) {
        lock.withLock { later[key] = (trigger, status, body) }
    }

    var requests: [(key: String, body: Data?)] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path.replacingOccurrences(of: "/api/v1", with: "") ?? ""
        let key = "\(request.httpMethod ?? "GET") \(path)"
        let route: (status: Int, body: String)? = lock.withLock {
            recorded.append((key, request.httpBody))
            if let next = later[key], recorded.contains(where: { $0.key == next.trigger }) { return (next.status, next.body) }
            return routes[key]
        }
        guard let route, let url = request.url else { throw URLError(.cannotConnectToHost) }
        return (Data(route.body.utf8), HTTPURLResponse(url: url, statusCode: route.status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
@Suite struct IOSAccountTests {
    private let accountID = "u1"
    private let phoneID = "phone"
    private let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!

    private struct Rig {
        var account: IOSAccount
        var server: FakeAccountServer
        var keys: MemorySecretStore
        var phone: DeviceIdentity
        var mac: DeviceIdentity
        var syncKey: SymmetricKey
        var defaults: UserDefaults
    }

    private func me(approved: Bool) -> String {
        """
        {"ok":true,"user":{"id":"u1","email":"anna@example.com"},"device":{"id":"phone","approved":\(approved)},\
        "devices":[{"id":"mac","name":"Studio","platform":"macos","approved":true,"created_at":"","last_seen_at":"","current":false,"public_key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="},\
        {"id":"phone","name":"iPhone","platform":"ios","approved":\(approved),"created_at":"","last_seen_at":"","current":true,"public_key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="}]}
        """
    }

    private func makeRig(
        signedIn: Bool = true, fastInterval: Duration = .seconds(3), fastLength: TimeInterval = 180,
        fastLimit: TimeInterval = 600
    ) async throws -> Rig {
        let keys = MemorySecretStore()
        if signedIn {
            let session = Session(
                token: "tok", user: AccountUser(id: accountID, email: "anna@example.com", name: nil, githubLogin: nil),
                device: DeviceRef(id: phoneID, approved: false))
            try keys.save(try JSONEncoder().encode(session), account: AccountClient.sessionAccount)
        }
        let identities = DeviceIdentityStore(secrets: MemorySecretStore())
        let phone = try await identities.load()
        let mac = try await DeviceIdentityStore(secrets: MemorySecretStore()).load()
        let server = FakeAccountServer()
        let defaults = UserDefaults(suiteName: "ios-account-tests-\(UUID().uuidString)")!
        let sinkFile = FileManager.default.temporaryDirectory.appending(path: "acct-\(UUID().uuidString)/access.json")
        let account = IOSAccount(
            keys: keys, identities: identities,
            sink: AccountAccessSink(secrets: MemorySecretStore(), file: sinkFile),
            noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()), http: server, deviceName: "iPhone",
            defaults: defaults, pollInterval: .milliseconds(5), fastInterval: fastInterval,
            fastWindowLength: fastLength, fastWindowLimit: fastLimit, syncPause: {})
        return Rig(
            account: account, server: server, keys: keys, phone: phone, mac: mac, syncKey: SymmetricKey(size: .bits256),
            defaults: defaults)
    }

    /// The blob of the account at `version`, sealed with `key` as the Mac would have left it.
    private func blob(_ rig: Rig, version: Int) throws -> String {
        let payload = SyncPayload(servers: [
            SyncedServer(
                id: serverID, name: "vps", endpoint: .ssh(host: "h", user: nil, port: nil), addedAt: 1,
                phone: SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK"))
        ])
        return try SyncKey.sealBlob(
            JSONEncoder().encode(payload), key: rig.syncKey,
            associatedData: SyncKey.blobAssociatedData(accountID: accountID, version: version))
    }

    private func wait(_ timeout: Double = 3, until condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aNewPhoneWaitsConfirmsTheMacsCodeAndBecomesReady() async throws {
        let rig = try await makeRig()
        rig.server.set("GET /me", me(approved: false))
        #expect(rig.account.stage == .loading)

        await rig.account.start()
        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))

        // The Mac approves: its envelope appears. The phone shows the Mac's code and keeps the key out until confirmed.
        let envelope = try SyncKey.seal(
            rig.syncKey, forPublicKey: rig.phone.publicKeyBase64, sender: rig.mac, accountID: accountID, deviceID: phoneID)
        rig.server.set("GET /devices/me/envelope", #"{"ok":true,"envelope":"\#(envelope)","from_public_key":"x"}"#)
        #expect(await wait { rig.account.stage == .confirmSender(code: rig.mac.fingerprint) })
        #expect(try SyncKey.load(from: rig.keys) == nil, "the key is not kept before the codes are confirmed")

        // Confirmed: the account is read again, now approved and with the Mac's blob.
        rig.server.set("GET /me", me(approved: true))
        rig.server.set("GET /sync", #"{"ok":true,"version":1,"blob":"\#(try blob(rig, version: 1))"}"#)
        rig.server.set("PUT /sync", #"{"ok":true,"version":2}"#)
        await rig.account.confirmSender()
        #expect(rig.account.stage == .ready)
        #expect(try SyncKey.load(from: rig.keys) != nil)

        // The phone asks for the server it has no token for, and shows it as waiting for the Mac.
        #expect(await wait { rig.account.servers.map(\.status) == [.waitingForMac] })
        let put = try #require(rig.server.requests.last { $0.key == "PUT /sync" })
        let putBody = try #require(put.body)
        let body = try #require(try JSONSerialization.jsonObject(with: putBody) as? [String: Any])
        let sealed = try #require(body["blob"] as? String)
        let written = try JSONDecoder().decode(
            SyncPayload.self,
            from: try SyncKey.openBlob(
                sealed, key: rig.syncKey, associatedData: SyncKey.blobAssociatedData(accountID: accountID, version: 2)))
        let request = try #require(written.accessRequests.first)
        #expect(request.deviceID == phoneID && request.serverID == serverID.uuidString.lowercased())
        #expect(request.publicKey == rig.phone.publicKeyBase64)
        #expect(written.servers.count == 1, "the Mac's server list is kept")
    }

    @Test func aWrongCodeRemovesThePhoneFromTheAccountAndDropsTheKey() async throws {
        let rig = try await makeRig()
        rig.server.set("GET /me", me(approved: false))
        await rig.account.start()
        let envelope = try SyncKey.seal(
            rig.syncKey, forPublicKey: rig.phone.publicKeyBase64, sender: rig.mac, accountID: accountID, deviceID: phoneID)
        rig.server.set("GET /devices/me/envelope", #"{"ok":true,"envelope":"\#(envelope)","from_public_key":"x"}"#)
        #expect(await wait { rig.account.stage == .confirmSender(code: rig.mac.fingerprint) })

        rig.server.set("DELETE /devices/phone", #"{"ok":true}"#)
        await rig.account.refuseSender()
        #expect(rig.account.stage == .rejected)
        #expect(rig.server.requests.contains { $0.key == "DELETE /devices/phone" })
        #expect(try SyncKey.load(from: rig.keys) == nil)

        await rig.account.acknowledgeRejected()
        #expect(rig.account.stage == .signedOut)
        #expect(try rig.keys.load(account: AccountClient.sessionAccount) == nil)
    }

    @Test func aFailedRefusalKeepsTheScreenAndSaysSo() async throws {
        let rig = try await makeRig()
        rig.server.set("GET /me", me(approved: false))
        await rig.account.start()
        let envelope = try SyncKey.seal(
            rig.syncKey, forPublicKey: rig.phone.publicKeyBase64, sender: rig.mac, accountID: accountID, deviceID: phoneID)
        rig.server.set("GET /devices/me/envelope", #"{"ok":true,"envelope":"\#(envelope)","from_public_key":"x"}"#)
        #expect(await wait { rig.account.stage == .confirmSender(code: rig.mac.fingerprint) })
        // The server cannot be reached: no route for DELETE.
        await rig.account.refuseSender()
        #expect(rig.account.stage != .rejected)
        #expect(rig.account.errorText != nil)
    }

    @Test func aSessionTheServerForgotSignsThePhoneOutHere() async throws {
        let rig = try await makeRig()
        rig.server.set("GET /me", #"{"ok":false,"error":"unauthorized"}"#, status: 401)
        await rig.account.start()
        #expect(rig.account.stage == .signedOut)
        #expect(try rig.keys.load(account: AccountClient.sessionAccount) == nil)
    }

    @Test func signingOutParksTheKeyAndEndsTheSession() async throws {
        let rig = try await makeRig()
        try SyncKey.save(rig.syncKey, to: rig.keys)
        rig.server.set("GET /me", me(approved: true))
        rig.server.set("GET /sync", #"{"ok":true,"version":1,"blob":"\#(try blob(rig, version: 1))"}"#)
        rig.server.set("PUT /sync", #"{"ok":true,"version":2}"#)
        rig.server.set("POST /auth/logout", #"{"ok":true}"#)
        await rig.account.start()
        #expect(rig.account.stage == .ready)

        await rig.account.signOut()

        #expect(rig.account.stage == .signedOut)
        #expect(rig.account.me == nil && rig.account.servers.isEmpty)
        #expect(try SyncKey.load(from: rig.keys) == nil)
        #expect(try ParkedSyncKey.loadParked(from: rig.keys)?.accountID == accountID)
        #expect(rig.server.requests.contains { $0.key == "POST /auth/logout" })
    }

    @Test func aSignedOutPhoneTouchesNothingOnStart() async throws {
        let rig = try await makeRig(signedIn: false)
        #expect(rig.account.stage == .signedOut)
        await rig.account.start()
        #expect(rig.server.requests.isEmpty)
    }

    @Test func aResetAccountWithVersionAboveZeroStillGetsItsFirstBlobAndTheScreenIsReady() async throws {
        // The reset left no blob but kept version 4: a write at version 0 would conflict for ever.
        let rig = try await makeRig()
        rig.server.set("GET /me", me(approved: true))
        rig.server.set("GET /sync", #"{"ok":true,"version":4,"blob":null}"#)
        rig.server.set("PUT /sync", #"{"ok":true,"version":5}"#)

        await rig.account.start()

        #expect(rig.account.stage == .ready)
        #expect(rig.account.errorText == nil)
        let put = try #require(rig.server.requests.last { $0.key == "PUT /sync" })
        let raw = try #require(put.body)
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(body["version"] as? Int == 4)
    }

    @Test func aConflictOnTheFirstWriteShowsNoErrorAndTheScreenStaysReady() async throws {
        // A parked key was restored, the account has no blob yet, and every write loses to another device.
        let rig = try await makeRig()
        try SyncKey.save(rig.syncKey, to: rig.keys)
        rig.server.set("GET /me", me(approved: true))
        rig.server.set("GET /sync", #"{"ok":true,"version":0,"blob":null}"#)
        rig.server.set("PUT /sync", #"{"ok":false,"error":"conflict","version":1}"#, status: 409)

        await rig.account.start()

        #expect(rig.account.stage == .ready)
        #expect(rig.account.errorText == nil)
        #expect(rig.account.errorDetails == nil)
        #expect(try SyncKey.load(from: rig.keys) != nil)
        #expect(rig.server.requests.filter { $0.key == "GET /me" }.count == 2, "the route was read again once")
    }

    @Test func theLoserOfARaceForTheFirstBlobWaitsForApprovalAndAsksForTheKey() async throws {
        let rig = try await makeRig()
        rig.server.set("GET /me", me(approved: true))
        // The account has no blob, this iPhone writes the first one, but the Mac's blob wins in between.
        rig.server.set("GET /sync", #"{"ok":true,"version":0,"blob":null}"#)
        rig.server.set("GET /sync", after: "PUT /sync", #"{"ok":true,"version":1,"blob":"\#(try blob(rig, version: 1))"}"#)
        rig.server.set("PUT /sync", #"{"ok":false,"error":"conflict","version":1}"#, status: 409)
        rig.server.set("POST /devices/me/request-key", #"{"ok":true}"#)
        rig.server.set("GET /me", after: "POST /devices/me/request-key", me(approved: false))

        await rig.account.start()

        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))
        #expect(rig.account.errorText == nil)
        #expect(try SyncKey.load(from: rig.keys) == nil, "the iPhone's own key is gone")
        #expect(rig.server.requests.filter { $0.key == "POST /devices/me/request-key" }.count == 1)
    }

    // MARK: fast rounds

    /// A ready account whose one server waits for the Mac.
    private func readyRig(fastInterval: Duration, fastLength: TimeInterval, fastLimit: TimeInterval) async throws -> Rig {
        let rig = try await makeRig(fastInterval: fastInterval, fastLength: fastLength, fastLimit: fastLimit)
        try SyncKey.save(rig.syncKey, to: rig.keys)
        rig.server.set("GET /me", me(approved: true))
        rig.server.set("GET /sync", #"{"ok":true,"version":1,"blob":"\#(try blob(rig, version: 1))"}"#)
        rig.server.set("PUT /sync", #"{"ok":true,"version":2}"#)
        rig.server.set("POST /auth/logout", #"{"ok":true}"#)
        return rig
    }

    private func rounds(_ rig: Rig) -> Int { rig.server.requests.filter { $0.key == "GET /me" }.count }

    @Test func aPhoneThatBecomesReadyAsksAgainEveryFewSecondsAndSlowsDownWhenTheWindowEnds() async throws {
        let rig = try await readyRig(fastInterval: .milliseconds(30), fastLength: 0.3, fastLimit: 0.6)
        await rig.account.start()
        rig.account.setActive(true)
        let base = rounds(rig)
        #expect(rig.account.fastMode)
        #expect(await wait { rounds(rig) >= base + 3 }, "more rounds follow at the fast pace, not a minute apart")

        // The window ends (it never runs past its limit in a row): back to the slow pace.
        #expect(await wait(3) { !rig.account.fastMode })
        try await Task.sleep(for: .milliseconds(200))
        let settled = rounds(rig)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rounds(rig) == settled)
        rig.account.setActive(false)
    }

    @Test func openingTheWindowWakesTheLoopThatIsAsleep() async throws {
        let rig = try await readyRig(fastInterval: .milliseconds(30), fastLength: 0.1, fastLimit: 0.1)
        await rig.account.start()
        rig.account.setActive(true)
        #expect(await wait(3) { !rig.account.fastMode })
        try await Task.sleep(for: .milliseconds(200))
        let asleep = rounds(rig)
        // The waiting interval is 10 seconds: only the wake-up can run a round now.
        rig.account.openFastWindow()
        #expect(await wait(2) { rounds(rig) > asleep })
        rig.account.setActive(false)
    }

    @Test func signingOutDuringFastRoundsStopsTheLoop() async throws {
        let rig = try await readyRig(fastInterval: .milliseconds(30), fastLength: 5, fastLimit: 5)
        await rig.account.start()
        rig.account.setActive(true)
        #expect(await wait { rounds(rig) >= 3 })

        await rig.account.signOut()
        #expect(rig.account.stage == .signedOut && !rig.account.fastMode && rig.account.servers.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        let settled = rounds(rig)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rounds(rig) == settled)
    }

    @Test func aReadyPhoneSaysItIsGettingItsServersUntilTheFirstRoundComesBack() async throws {
        let rig = try await readyRig(fastInterval: .milliseconds(30), fastLength: 5, fastLimit: 5)
        await rig.account.start()
        #expect(rig.account.stage == .ready)
        #expect(rig.account.fetchingServers, "ready, nothing read yet, fast window open")
        #expect(await wait { !rig.account.servers.isEmpty })
        #expect(!rig.account.fetchingServers)
        #expect(rig.account.servers.map(\.status) == [.waitingForMac])
    }
}
