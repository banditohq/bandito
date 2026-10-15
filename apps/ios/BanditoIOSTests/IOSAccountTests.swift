import BanditoKit
import BanditoL10n
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
        signedIn: Bool = true, fastLength: TimeInterval = 180, fastLimit: TimeInterval = 600, clock: ManualClock? = nil,
        joinTimeout: Duration = .seconds(120), retryDelay: Duration = .milliseconds(1500)
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
            defaults: defaults, pollInterval: .milliseconds(5), retryDelay: retryDelay,
            fastWindowLength: fastLength, fastWindowLimit: fastLimit, joinTimeout: joinTimeout,
            now: { clock?.now ?? Date() }, sleep: { duration in
                if let clock { await clock.sleep(duration) } else { try? await Task.sleep(for: duration) }
            }, syncPause: {})
        return Rig(
            account: account, server: server, keys: keys, phone: phone, mac: mac, syncKey: SymmetricKey(size: .bits256),
            defaults: defaults)
    }

    /// The blob of the account at `version`, sealed with `key` as the Mac would have left it.
    private func blob(_ rig: Rig, version: Int, asked: Bool = false) throws -> String {
        var payload = SyncPayload(servers: [
            SyncedServer(
                id: serverID, name: "vps", endpoint: .ssh(host: "h", user: nil, port: nil), addedAt: 1,
                phone: SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK"))
        ])
        if asked {
            // This iPhone's request is already in the blob, so a round has nothing to write.
            payload.accessRequests = [
                AccessRequest(
                    deviceID: phoneID, serverID: serverID.uuidString.lowercased(), noiseKey: "k",
                    publicKey: rig.phone.publicKeyBase64, at: 1)
            ]
        }
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

    /// A ready account whose one server waits for the Mac. `asked`: the request is already written.
    // MARK: sign-in with a Mac's code

    private let redeemed = #"{"ok":true,"token":"tok2","user":{"id":"u1","email":"anna@example.com"},"device":{"id":"phone","approved":false}}"#

    /// The redeem of a ticket needs the challenge first (the device block is signed over its nonce).
    private func setRedeem(_ rig: Rig, _ body: String? = nil, status: Int = 200) {
        let nonce = Data(repeating: 7, count: 64).base64EncodedString()
        rig.server.set("POST /auth/challenge", #"{"ok":true,"nonce":"\#(nonce)","expires_in":300}"#)
        rig.server.set("POST /auth/ticket/redeem", body ?? redeemed, status: status)
    }

    private func makeTicket(for mac: DeviceIdentity, name: String = "Studio 🦝") throws -> JoinTicket {
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: try #require(Data(base64Encoded: mac.publicKeyBase64)))
        return JoinTicket.make(macPublicKey: key, macName: name)
    }

    /// The server as it is once the Mac approved: the account reads as approved, with the Mac's blob, and the envelope is there.
    private func macApproves(_ rig: Rig, sender: DeviceIdentity? = nil) throws {
        rig.server.set("GET /me", me(approved: true))
        rig.server.set("GET /sync", #"{"ok":true,"version":1,"blob":"\#(try blob(rig, version: 1, asked: true))"}"#)
        rig.server.set("PUT /sync", #"{"ok":true,"version":2}"#)
        let envelope = try SyncKey.seal(
            rig.syncKey, forPublicKey: rig.phone.publicKeyBase64, sender: sender ?? rig.mac, accountID: accountID, deviceID: phoneID)
        rig.server.set("GET /devices/me/envelope", #"{"ok":true,"envelope":"\#(envelope)","from_public_key":"x"}"#)
    }

    @Test func aScannedCodeSignsInWaitsForTheMacAndTakesItsKeyWithoutAQuestion() async throws {
        let rig = try await makeRig(signedIn: false)
        setRedeem(rig)
        rig.server.set("GET /me", me(approved: false))
        let ticket = try makeTicket(for: rig.mac)

        let result = await rig.account.join(ticket)
        #expect(result == .joining)
        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))
        #expect(rig.account.joinMacName == "Studio 🦝")
        let redeem = try #require(rig.server.requests.first { $0.key == "POST /auth/ticket/redeem" })
        let redeemBody = try #require(redeem.body)
        let body = try #require(try JSONSerialization.jsonObject(with: redeemBody) as? [String: Any])
        #expect(body["ticket"] as? String == ticket.authToken)

        try macApproves(rig)
        #expect(await wait { rig.account.stage == .ready })
        #expect(try SyncKey.load(from: rig.keys) != nil)
        #expect(rig.account.joinMacName == nil && rig.account.joinProblem == nil)
        #expect(rig.account.fastMode, "the servers are asked for at the fast pace")
    }

    @Test func aKeyFromAnotherSenderIsNotTakenAndTheCodesCanBeComparedByHand() async throws {
        let rig = try await makeRig(signedIn: false)
        setRedeem(rig)
        rig.server.set("GET /me", me(approved: false))
        // The code is of one Mac, the envelope is sealed by another device.
        let other = try await DeviceIdentityStore(secrets: MemorySecretStore()).load()
        await rig.account.join(try makeTicket(for: other))
        try macApproves(rig)

        #expect(await wait { rig.account.joinProblem == .foreign })
        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))
        #expect(try SyncKey.load(from: rig.keys) == nil)

        rig.account.compareManually()
        #expect(rig.account.stage == .confirmSender(code: rig.mac.fingerprint))
        #expect(rig.account.joinProblem == nil)
    }

    @Test func aStaleCodeSaysSoAndLeavesThePhoneSignedOut() async throws {
        let rig = try await makeRig(signedIn: false)
        setRedeem(rig, #"{"ok":false,"error":"ticket_invalid"}"#, status: 404)

        await rig.account.join(try makeTicket(for: rig.mac))
        #expect(rig.account.stage == .signedOut)
        #expect(rig.account.errorText == L10n.Ios.Join.expired)
        #expect(rig.account.joinMacName == nil)
        #expect(try rig.keys.load(account: AccountClient.sessionAccount) == nil)
    }

    @Test func aScanWithoutNetworkSaysSoAndALaterScanWorks() async throws {
        let rig = try await makeRig(signedIn: false, retryDelay: .milliseconds(1))
        // No route: the request fails on the network.
        await rig.account.join(try makeTicket(for: rig.mac))
        #expect(rig.account.stage == .signedOut)
        #expect(rig.account.errorText == L10n.Onboarding.Failure.network)

        setRedeem(rig)
        rig.server.set("GET /me", me(approved: false))
        await rig.account.join(try makeTicket(for: rig.mac))
        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))
        #expect(rig.account.errorText == nil)
    }

    @Test func aMacThatStaysSilentIsSaidAfterTheTimeoutAndItsLateKeyIsStillTaken() async throws {
        let rig = try await makeRig(signedIn: false, joinTimeout: .milliseconds(40))
        setRedeem(rig)
        rig.server.set("GET /me", me(approved: false))
        await rig.account.join(try makeTicket(for: rig.mac))
        #expect(rig.account.joinMacName != nil)

        #expect(await wait { rig.account.joinProblem == .silent })
        // The session stays: the ordinary approval screen shows.
        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))
        #expect(rig.account.joinMacName == nil)
        #expect(try rig.keys.load(account: AccountClient.sessionAccount) != nil)

        try macApproves(rig)
        #expect(await wait { rig.account.stage == .ready })
        #expect(rig.account.joinProblem == nil)
    }

    @Test func aPhoneThatIsInTheAccountIsNotSignedInAgain() async throws {
        let (rig, _) = try await readyRig()
        await rig.account.start()
        #expect(rig.account.stage == .ready)

        let result = await rig.account.join(try makeTicket(for: rig.mac))
        #expect(result == .alreadySignedIn)
        #expect(rig.account.stage == .ready)
        #expect(rig.account.fastMode)
        #expect(!rig.server.requests.contains { $0.key == "POST /auth/ticket/redeem" })
    }

    @Test func aPendingDeviceFromAnEmailSignInStillJoinsWithTheSameDevice() async throws {
        let rig = try await makeRig()
        rig.server.set("GET /me", me(approved: false))
        await rig.account.start()
        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))

        setRedeem(rig)
        await rig.account.join(try makeTicket(for: rig.mac))
        #expect(rig.server.requests.contains { $0.key == "POST /auth/ticket/redeem" })
        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))

        try macApproves(rig)
        #expect(await wait { rig.account.stage == .ready })
    }

    @Test func aFailedScanOfAPendingPhoneKeepsItWaitingForItsOrdinaryApproval() async throws {
        let rig = try await makeRig()
        rig.server.set("GET /me", me(approved: false))
        await rig.account.start()
        setRedeem(rig, #"{"ok":false,"error":"ticket_invalid"}"#, status: 404)

        await rig.account.join(try makeTicket(for: rig.mac))
        #expect(rig.account.stage == .waitingForApproval(code: rig.phone.fingerprint))
        #expect(rig.account.errorText == L10n.Ios.Join.expired)

        // The polling went on: the ordinary approval still arrives.
        let envelope = try SyncKey.seal(
            rig.syncKey, forPublicKey: rig.phone.publicKeyBase64, sender: rig.mac, accountID: accountID, deviceID: phoneID)
        rig.server.set("GET /devices/me/envelope", #"{"ok":true,"envelope":"\#(envelope)","from_public_key":"x"}"#)
        #expect(await wait { rig.account.stage == .confirmSender(code: rig.mac.fingerprint) })
    }

    private func readyRig(asked: Bool = true, fastLength: TimeInterval = 180, fastLimit: TimeInterval = 600) async throws -> (Rig, ManualClock) {
        let clock = ManualClock()
        let rig = try await makeRig(fastLength: fastLength, fastLimit: fastLimit, clock: clock)
        try SyncKey.save(rig.syncKey, to: rig.keys)
        rig.server.set("GET /me", me(approved: true))
        rig.server.set("GET /sync", #"{"ok":true,"version":1,"blob":"\#(try blob(rig, version: 1, asked: asked))"}"#)
        rig.server.set("PUT /sync", #"{"ok":true,"version":2}"#)
        rig.server.set("POST /auth/logout", #"{"ok":true}"#)
        return (rig, clock)
    }

    /// Lets the sleeping loop wake `seconds` later by the fake clock and waits for the round it runs.
    private func step(_ rig: Rig, _ clock: ManualClock, by seconds: TimeInterval) async -> Bool {
        let before = rig.account.cycleRuns
        clock.now = clock.now.addingTimeInterval(seconds)
        clock.release()
        return await wait { rig.account.cycleRuns > before && clock.isSleeping && !rig.account.cycling }
    }

    @Test func aPhoneThatBecomesReadyAsksAgainAtTheFastPaceAndSlowsDownWhenTheWindowEnds() async throws {
        let (rig, clock) = try await readyRig()
        await rig.account.start()
        rig.account.setActive(true)
        #expect(await wait { rig.account.loadedServers && clock.isSleeping && !rig.account.cycling })
        #expect(rig.account.fastMode)
        #expect(clock.sleeps.last == .seconds(3), "the second round is 3 seconds away, not a minute")
        #expect(await step(rig, clock, by: 3))
        #expect(await step(rig, clock, by: 3))
        #expect(clock.sleeps.last == .seconds(3))

        // 181 seconds after the window opened it has run out: the slow pace for a server that waits.
        #expect(await step(rig, clock, by: 200))
        #expect(!rig.account.fastMode)
        #expect(clock.sleeps.last == .seconds(10))
        // The loop is alive: the next round does come, at the slow pace.
        let before = rig.account.cycleRuns
        #expect(await step(rig, clock, by: 10))
        #expect(rig.account.cycleRuns == before + 1)
        #expect(clock.sleeps.last == .seconds(10))
        rig.account.setActive(false)
    }

    @Test func aServerThatKeepsWaitingKeepsTheWindowOnlyUpToItsLimit() async throws {
        let (rig, clock) = try await readyRig()
        await rig.account.start()
        rig.account.setActive(true)
        #expect(await wait { rig.account.loadedServers && clock.isSleeping && !rig.account.cycling })
        for _ in 0..<5 {
            #expect(await step(rig, clock, by: 100))
            #expect(rig.account.fastMode && clock.sleeps.last == .seconds(3))
        }
        // 500 s in, the window is lengthened to the 600 s limit; after it the pace is slow.
        #expect(await step(rig, clock, by: 101))
        #expect(!rig.account.fastMode && clock.sleeps.last == .seconds(10))
        rig.account.setActive(false)
    }

    @Test func aRoundThatWritesRequestsStartsAFastWindow() async throws {
        let (rig, clock) = try await readyRig(asked: false, fastLength: 30, fastLimit: 30)
        await rig.account.start()
        // The window of the sign-in has run out before the first round runs; that round writes a request (the blob has
        // none), and that opens a window again.
        clock.now = clock.now.addingTimeInterval(100)
        rig.account.setActive(true)
        #expect(await wait { rig.account.loadedServers && clock.isSleeping && !rig.account.cycling })
        #expect(rig.server.requests.contains { $0.key == "PUT /sync" })
        #expect(rig.account.fastMode && clock.sleeps.last == .seconds(3))
        rig.account.setActive(false)
    }

    @Test func openingTheWindowWakesTheLoopThatIsAsleep() async throws {
        let (rig, clock) = try await readyRig(fastLength: 30, fastLimit: 30)
        await rig.account.start()
        rig.account.setActive(true)
        #expect(await wait { rig.account.loadedServers && clock.isSleeping && !rig.account.cycling })
        #expect(await step(rig, clock, by: 100))
        #expect(clock.sleeps.last == .seconds(10), "asleep for ten seconds")
        let asleep = rig.account.cycleRuns
        rig.account.openFastWindow()
        #expect(await wait { rig.account.cycleRuns > asleep }, "no release of the clock: only the wake-up can run it")
        #expect(await wait { clock.isSleeping })
        #expect(clock.sleeps.last == .seconds(3))
        rig.account.setActive(false)
    }

    @Test func aReturnToTheFrontOpensTheWindowOnlyAfterTheLimitHasPassedAgain() async throws {
        let (rig, clock) = try await readyRig()
        await rig.account.start()
        rig.account.setActive(true)
        #expect(await wait { rig.account.loadedServers && clock.isSleeping && !rig.account.cycling })
        for _ in 0..<5 { #expect(await step(rig, clock, by: 100)) }
        #expect(await step(rig, clock, by: 101))
        #expect(!rig.account.fastMode, "ended at its 10 minute limit")

        // A minute later the return is no news.
        rig.account.setActive(false)
        clock.now = clock.now.addingTimeInterval(60)
        rig.account.setActive(true)
        #expect(!rig.account.fastMode)
        // Eleven minutes after the end it is.
        rig.account.setActive(false)
        clock.now = clock.now.addingTimeInterval(11 * 60)
        rig.account.setActive(true)
        #expect(rig.account.fastMode)
        rig.account.setActive(false)
    }

    @Test func signingOutDuringFastRoundsStopsTheLoop() async throws {
        let (rig, clock) = try await readyRig()
        await rig.account.start()
        rig.account.setActive(true)
        #expect(await wait { rig.account.loadedServers && clock.isSleeping && !rig.account.cycling })
        #expect(await step(rig, clock, by: 3))

        await rig.account.signOut()
        #expect(rig.account.stage == .signedOut && !rig.account.fastMode && rig.account.servers.isEmpty)
        let settled = rig.account.cycleRuns
        clock.release()
        #expect(!(await wait(0.3) { rig.account.cycleRuns > settled }), "no round after signing out")
    }

    @Test func aCallThatComesDuringARoundIsNotLostButRunsOnce() async throws {
        let (rig, _) = try await readyRig()
        await rig.account.start()
        #expect(await wait { rig.account.loadedServers && !rig.account.cycling })
        let before = rig.account.cycleRuns
        let account = rig.account
        let calls = (0..<3).map { _ in Task { @MainActor in await account.runCycle() } }
        for call in calls { await call.value }
        #expect(rig.account.cycleRuns == before + 2, "the round, and exactly one more for the calls that came meanwhile")
    }

    @Test func aReadyPhoneSaysItIsGettingItsServersUntilTheFirstRoundComesBack() async throws {
        let (rig, _) = try await readyRig()
        await rig.account.start()
        #expect(rig.account.stage == .ready)
        #expect(rig.account.fetchingServers, "ready, nothing read yet, fast window open")
        #expect(await wait { !rig.account.servers.isEmpty })
        #expect(!rig.account.fetchingServers)
        #expect(rig.account.servers.map(\.status) == [.waitingForMac])
    }
}

/// The sleep and the clock of the round loop in a test: a sleep waits until the test releases it (or the loop cancels it).
@MainActor
final class ManualClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private(set) var sleeps: [Duration] = []
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    var isSleeping: Bool { !waiting.isEmpty }

    func sleep(_ duration: Duration) async {
        sleeps.append(duration)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting.append((id, $0)) }
        } onCancel: {
            Task { @MainActor in self.resume(id) }
        }
    }

    func release() {
        let all = waiting
        waiting = []
        for entry in all { entry.continuation.resume() }
    }

    private func resume(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume()
    }
}
