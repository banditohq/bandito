import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

// MARK: - fakes

/// The account's blob in memory. `failNextUpdate` makes the next write fail once, as a lost connection would.
@MainActor
final class AccessFakeSync: AccessSyncing {
    var payload: SyncPayload?
    var failNextUpdate = false
    var updates = 0

    init(_ payload: SyncPayload?) { self.payload = payload }

    func pull() async throws -> SyncPayload? { payload }

    func update(_ mutate: (inout SyncPayload) -> Void) async throws -> SyncPayload {
        if failNextUpdate {
            failNextUpdate = false
            throw AccountError.network("down")
        }
        var next = payload ?? SyncPayload()
        mutate(&next)
        payload = next
        updates += 1
        return next
    }
}

struct AccessFakeAccount: AccessAccount {
    var userID = "u1"
    var deviceID: String
    var devices: [AccountDevice]
    var approved = true

    func me() async throws -> Me {
        Me(
            user: AccountUser(id: userID, email: nil, name: nil, githubLogin: nil),
            device: DeviceRef(id: deviceID, approved: approved), devices: devices)
    }

    func restoreSession() async throws -> Session? {
        Session(
            token: "t", user: AccountUser(id: userID, email: nil, name: nil, githubLogin: nil),
            device: DeviceRef(id: deviceID, approved: approved))
    }
}

/// A daemon with a list of device rows.
@MainActor
final class AccessFakeDaemon: AccessServer {
    let accessServerID: UUID
    var isReachable = true
    var rows: [Device] = [Device(id: "row-me", name: "Mac", createdAt: 0, lastSeenAt: nil, current: true, platform: nil)]
    var issuedCalls: [(name: String, platform: String, noiseKey: String?)] = []
    var refuse: RPCError?
    private var counter = 0

    init(_ id: UUID) { accessServerID = id }

    func issueDeviceToken(name: String, platform: String, noiseKey: String?) async throws -> IssuedDevice {
        if let refuse { throw refuse }
        issuedCalls.append((name, platform, noiseKey))
        counter += 1
        let id = "row-\(counter)"
        rows.append(Device(id: id, name: name, createdAt: 0, lastSeenAt: nil, current: false, platform: platform))
        return IssuedDevice(deviceId: id, token: "bdt_token_\(counter)")
    }

    func phoneInfo() async throws -> PhoneInfo? { nil }
    func deviceRows() async throws -> [Device] { rows }
    func revokeDeviceRow(_ id: String) async throws { rows.removeAll { $0.id == id } }
}

actor AccessFakeSink: ServerAccessSink {
    var held: Set<UUID> = []
    var received: [ServerAccess] = []
    var fail = false

    func hasAccess(serverID: UUID) async -> Bool { held.contains(serverID) }

    func receive(_ access: ServerAccess) async throws {
        if fail { throw AccountError.network("down") }
        held.insert(access.serverID)
        received.append(access)
    }

    func setFail(_ value: Bool) { fail = value }
}

// MARK: - tests

@MainActor
@Suite struct AccessFlowTests {
    let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    let mac = try! makeIdentity()
    let phone = try! makeIdentity()
    let phoneInfo = SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK")
    var now = Date(timeIntervalSince1970: 3_000_000)

    func devices(phoneKey: String? = nil) -> [AccountDevice] {
        [
            AccountDevice(id: "mac", name: "Studio", platform: "macos", approved: true),
            AccountDevice(id: "phone", name: "Anna's iPhone", platform: "ios", approved: true, publicKey: phoneKey),
        ]
    }

    func blobWithServer() -> SyncPayload {
        SyncPayload(servers: [
            SyncedServer(id: serverID, name: "vps", endpoint: .ssh(host: "h", user: nil, port: nil), addedAt: 1, phone: phoneInfo)
        ])
    }

    func suite(
        sync: AccessFakeSync, devices: [AccountDevice]? = nil, defaults: UserDefaults? = nil
    ) -> (AccessResponder, AccessRequester, AccessFakeSink, AccessLedger) {
        let list = devices ?? self.devices()
        let sink = AccessFakeSink()
        let ledger = AccessLedger(defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!)
        let clock = now
        let responder = AccessResponder(
            sync: sync, account: AccessFakeAccount(deviceID: "mac", devices: list), identity: mac, ledger: ledger,
            now: { clock })
        let requester = AccessRequester(
            sync: sync, account: AccessFakeAccount(deviceID: "phone", devices: list), identity: phone, sink: sink,
            noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { clock })
        return (responder, requester, sink, ledger)
    }

    @Test func aPhoneAsksTheMacAnswersAndThePhoneConnects() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, sink, ledger) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)

        // The phone sees a server it has no token for and asks.
        let states = try await requester.run()
        #expect(states.map(\.status) == [.waitingForMac])
        let request = try #require(sync.payload?.accessRequests.first)
        #expect(request.deviceID == "phone" && request.serverID == serverID.uuidString.lowercased())
        #expect(request.publicKey == phone.publicKeyBase64)
        #expect(request.noiseKey.count == 43)  // 32 bytes, base64url without padding

        // Asking again changes nothing.
        let writes = sync.updates
        _ = try await requester.run()
        #expect(sync.updates == writes)

        // The Mac answers: a device with the phone's name and its Noise key, the request gone, a grant written.
        let outcome = try await responder.run(servers: [server])
        #expect(outcome.issued == 1)
        #expect(server.issuedCalls.count == 1)
        #expect(server.issuedCalls[0].name == "Anna's iPhone" && server.issuedCalls[0].platform == "ios")
        #expect(server.issuedCalls[0].noiseKey == request.noiseKey)
        #expect(sync.payload?.accessRequests.isEmpty == true)
        let grant = try #require(sync.payload?.accessGrants.first)
        #expect(!grant.sealed.contains("bdt_"))
        #expect(ledger.issues.first?.pending == nil)

        // The phone opens it, hands it to the sink and cleans up.
        let after = try await requester.run()
        #expect(after.map(\.status) == [.connected])
        let received = await sink.received
        #expect(received.count == 1)
        #expect(received[0].deviceToken == "bdt_token_1" && received[0].serverID == serverID)
        #expect(received[0].name == "vps" && received[0].phone == phoneInfo)
        #expect(sync.payload?.accessGrants.isEmpty == true && sync.payload?.accessRequests.isEmpty == true)
    }

    @Test func aRequestIsAnsweredOnceEvenIfItComesBack() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, _, _) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)
        _ = try await requester.run()
        let request = try #require(sync.payload?.accessRequests.first)

        _ = try await responder.run(servers: [server])
        // A merge from a stale device brings the same request back, and its grant was already taken away.
        sync.payload?.accessGrants = []
        sync.payload?.accessRequests = [request]
        let second = try await responder.run(servers: [server])
        #expect(second.issued == 0)
        #expect(server.issuedCalls.count == 1)
        #expect(sync.payload?.accessRequests.isEmpty == true, "the old request is removed, not answered")
    }

    @Test func aGrantThatCouldNotBeWrittenIsWrittenLaterWithoutAnotherToken() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, _, ledger) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)
        _ = try await requester.run()

        sync.failNextUpdate = true
        await #expect(throws: AccountError.self) { try await responder.run(servers: [server]) }
        #expect(server.issuedCalls.count == 1)
        #expect(ledger.issues.first?.pending != nil)
        #expect(sync.payload?.accessGrants.isEmpty == true)

        let retry = try await responder.run(servers: [server])
        #expect(retry.issued == 0)
        #expect(server.issuedCalls.count == 1, "one request, one device")
        #expect(sync.payload?.accessGrants.count == 1)
        #expect(sync.payload?.accessRequests.isEmpty == true)
        #expect(ledger.issues.first?.pending == nil)
    }

    @Test func aServerThatIsNotConnectedWaits() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, _, _) = suite(sync: sync)
        _ = try await requester.run()
        let offline = AccessFakeDaemon(serverID)
        offline.isReachable = false

        let outcome = try await responder.run(servers: [offline])
        #expect(outcome.waiting == 1 && outcome.issued == 0)
        #expect(offline.issuedCalls.isEmpty)
        #expect(sync.payload?.accessRequests.count == 1, "the request stays")

        // A server this device does not know at all waits too.
        let other = try await responder.run(servers: [])
        #expect(other.waiting == 1)
    }

    @Test func requestsFromUnknownOrUnapprovedDevicesAreIgnored() async throws {
        var payload = blobWithServer()
        payload.accessRequests = [
            AccessRequest(deviceID: "ghost", serverID: serverID.uuidString, noiseKey: "k", publicKey: phone.publicKeyBase64, at: Int64(now.timeIntervalSince1970 * 1000)),
            AccessRequest(deviceID: "new", serverID: serverID.uuidString, noiseKey: "k", publicKey: phone.publicKeyBase64, at: Int64(now.timeIntervalSince1970 * 1000)),
        ]
        let sync = AccessFakeSync(payload)
        var list = devices()
        list.append(AccountDevice(id: "new", name: "Pending", platform: "ios", approved: false))
        let (responder, _, _, _) = suite(sync: sync, devices: list)
        let server = AccessFakeDaemon(serverID)

        let outcome = try await responder.run(servers: [server])
        #expect(outcome.issued == 0 && server.issuedCalls.isEmpty)
    }

    @Test func aKeyThatDisagreesWithTheAccountListGetsNothing() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let other = try makeIdentity()
        // The account lists another key for the phone than the one its request carries.
        let (responder, requester, _, _) = suite(sync: sync, devices: devices(phoneKey: other.publicKeyBase64))
        _ = try await requester.run()
        let server = AccessFakeDaemon(serverID)
        let outcome = try await responder.run(servers: [server])
        #expect(outcome.failed == 1 && server.issuedCalls.isEmpty)
    }

    @Test func aDaemonThatRefusesTheRequestDropsItForGood() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, _, _) = suite(sync: sync)
        _ = try await requester.run()
        let server = AccessFakeDaemon(serverID)
        server.refuse = RPCError(code: RPCError.invalidParams, message: "noise_key")

        let outcome = try await responder.run(servers: [server])
        #expect(outcome.failed == 1)
        #expect(sync.payload?.accessRequests.isEmpty == true)
        #expect(sync.payload?.accessGrants.isEmpty == true)

        // Another failure (the daemon is down) keeps the request for the next cycle.
        _ = try await requester.run()
        server.refuse = RPCError(code: RPCError.disconnected, message: "down")
        _ = try await responder.run(servers: [server])
        #expect(sync.payload?.accessRequests.count == 1)
    }

    @Test func aGrantThatCannotBeTakenStaysUntilTheSinkWorks() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, sink, _) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)
        _ = try await requester.run()
        _ = try await responder.run(servers: [server])

        await sink.setFail(true)
        _ = try await requester.run()
        #expect(sync.payload?.accessGrants.count == 1)
        #expect(await sink.received.isEmpty)

        await sink.setFail(false)
        let states = try await requester.run()
        #expect(states.map(\.status) == [.connected])
        #expect(sync.payload?.accessGrants.isEmpty == true)
    }

    @Test func aGrantSealedForAnotherServerOrByAStrangerIsDroppedWithoutAToken() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let stranger = try makeIdentity()
        let (_, requester, sink, _) = suite(sync: sync)
        let forged = try DeviceTokenSeal.seal(
            token: "bdt_evil", forPublicKey: phone.publicKeyBase64, sender: stranger, accountID: "u1", deviceID: "phone",
            serverID: serverID.uuidString)
        sync.payload?.accessGrants = [
            AccessGrant(deviceID: "phone", serverID: serverID.uuidString, sealed: forged, at: Int64(now.timeIntervalSince1970 * 1000))
        ]
        // The account lists the Mac's key only: a grant from anyone else is refused.
        let list = devices().map { device -> AccountDevice in
            var copy = device
            if device.id == "mac" { copy.publicKey = mac.publicKeyBase64 }
            return copy
        }
        let (_, strict, strictSink, _) = suite(sync: sync, devices: list)
        _ = try await strict.run()
        #expect(await strictSink.received.isEmpty)
        #expect(sync.payload?.accessGrants.isEmpty == true)
        #expect(await sink.received.isEmpty)
        _ = requester
    }

    @Test func aServerWithoutAWayInIsNotAskedFor() async throws {
        var payload = blobWithServer()
        payload.servers[0].phone = nil
        let sync = AccessFakeSync(payload)
        let (_, requester, _, _) = suite(sync: sync)
        let states = try await requester.run()
        #expect(states.map(\.status) == [.noRemoteAccess])
        #expect(sync.payload?.accessRequests.isEmpty == true)
    }

    @Test func removingADeviceRevokesItsRowsOnTheServersThatAreReachable() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, _, ledger) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)
        _ = try await requester.run()
        _ = try await responder.run(servers: [server])
        // A row that was paired by hand under the same name (another Mac issued it), and the Mac's own.
        server.rows.append(Device(id: "row-hand", name: "Anna's iPhone", createdAt: 0, lastSeenAt: nil, current: false, platform: nil))
        #expect(server.rows.map(\.id).contains("row-1"))

        let offline = AccessFakeDaemon(UUID())
        offline.isReachable = false
        let count = await responder.revoke(deviceID: "phone", name: "Anna's iPhone", servers: [server, offline])
        #expect(count == 2)
        #expect(server.rows.map(\.id) == ["row-me"], "the Mac's own row stays")
        #expect(ledger.issues.isEmpty)
        #expect(sync.payload?.accessGrants.isEmpty == true)

        // The server that was offline is cleaned when it comes back.
        offline.rows.append(Device(id: "row-x", name: "Anna's iPhone", createdAt: 0, lastSeenAt: nil, current: false, platform: nil))
        offline.isReachable = true
        let later = try await responder.run(servers: [server, offline])
        #expect(later.revoked == 1)
        #expect(offline.rows.map(\.id) == ["row-me"])
    }

    @Test func aRowIssuedForAnotherDeviceOfTheSameNameIsNotRevokedByName() async throws {
        let sync = AccessFakeSync(blobWithServer())
        var list = devices()
        list.append(AccountDevice(id: "phone2", name: "Anna's iPhone", platform: "ios", approved: true))
        let (responder, _, _, ledger) = suite(sync: sync, devices: list)
        let server = AccessFakeDaemon(serverID)
        server.rows.append(Device(id: "row-p2", name: "Anna's iPhone", createdAt: 0, lastSeenAt: nil, current: false, platform: nil))
        ledger.record(
            AccessLedger.Issue(
                accountID: "u1", deviceID: "phone2", deviceName: "Anna's iPhone", serverID: serverID.uuidString.lowercased(),
                requestAt: 1, rowID: "row-p2", issuedAt: 1, pending: nil))
        _ = await responder.revoke(deviceID: "phone", name: "Anna's iPhone", servers: [server])
        #expect(server.rows.map(\.id).contains("row-p2"))
    }

    @Test func aSignedOutOrUnapprovedDeviceDoesNothing() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let sink = AccessFakeSink()
        let requester = AccessRequester(
            sync: sync, account: AccessFakeAccount(deviceID: "phone", devices: devices(), approved: false), identity: phone,
            sink: sink, noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(try await requester.run().isEmpty)
        #expect(sync.payload?.accessRequests.isEmpty == true)
    }

    @Test func theNoiseKeyOfAServerIsMadeOnceAndIsAValidKey() throws {
        let store = ServerNoiseKeyStore(secrets: MemorySecretStore())
        let a = try store.publicKey(for: serverID)
        #expect(try store.publicKey(for: serverID) == a)
        #expect(a.count == 43 && !a.contains("=") && !a.contains("+") && !a.contains("/"))
        #expect(try store.publicKey(for: UUID()) != a)
        try store.remove(serverID)
        #expect(try store.existingPrivateKey(for: serverID) == nil)
    }
}
