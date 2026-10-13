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
    /// Runs before each write: another device's change that lands between this one's read and write.
    var beforeUpdate: (() -> Void)?
    var pulls = 0

    init(_ payload: SyncPayload?) { self.payload = payload }

    /// Before the pull with this number, once: another device's change that lands between two reads of one cycle.
    var afterPulls: (count: Int, change: () -> Void)?

    func pull() async throws -> SyncPayload? {
        pulls += 1
        if let afterPulls, pulls == afterPulls.count {
            self.afterPulls = nil
            afterPulls.change()
        }
        return payload
    }

    func update(_ mutate: (inout SyncPayload) -> Void) async throws -> SyncPayload {
        if failNextUpdate {
            failNextUpdate = false
            throw AccountError.network("down")
        }
        beforeUpdate?()
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

/// A clock a test moves.
final class Clock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

@MainActor
@Suite struct AccessFlowTests {
    let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    let mac = try! makeIdentity()
    let phone = try! makeIdentity()
    let phoneInfo = SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK")
    var now = Date(timeIntervalSince1970: 3_000_000)

    /// The account's devices as `GET /me` lists them. With `keys` false it lists none (an older account service).
    func devices(keys: Bool = true, phoneKey: String? = nil) -> [AccountDevice] {
        [
            AccountDevice(
                id: "mac", name: "Studio", platform: "macos", approved: true, publicKey: keys ? mac.publicKeyBase64 : nil),
            AccountDevice(
                id: "phone", name: "Anna's iPhone", platform: "ios", approved: true,
                publicKey: keys ? (phoneKey ?? phone.publicKeyBase64) : nil),
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
        list.append(AccountDevice(id: "new", name: "Pending", platform: "ios", approved: false, publicKey: phone.publicKeyBase64))
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

    /// Phone asked, the Mac answered: returns the pieces for a test that goes on from there.
    private func answeredRig(sync: AccessFakeSync? = nil) async throws -> (
        AccessResponder, AccessFakeSync, AccessFakeDaemon, AccessLedger
    ) {
        let sync = sync ?? AccessFakeSync(blobWithServer())
        let (responder, requester, _, ledger) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)
        _ = try await requester.run()
        _ = try await responder.run(servers: [server])
        #expect(server.rows.map(\.id).contains("row-1"))
        return (responder, sync, server, ledger)
    }

    /// A responder whose account no longer lists the phone (removed from anywhere), over the same ledger and blob.
    private func responder(without ids: Set<String>, sync: AccessFakeSync, ledger: AccessLedger, approvedOnly: Bool = false) -> AccessResponder {
        var list = devices().filter { !ids.contains($0.id) }
        if approvedOnly { list = devices().map { var d = $0; if ids.contains(d.id) { d.approved = false }; return d } }
        return AccessResponder(
            sync: sync, account: AccessFakeAccount(deviceID: "mac", devices: list), identity: mac, ledger: ledger,
            now: { self.now })
    }

    @Test func aDeviceThatLeftTheAccountLosesTheRowsThisMacIssuedWhoeverRemovedIt() async throws {
        let (_, sync, server, ledger) = try await answeredRig()
        // A row paired by hand under the same name, and the Mac's own: neither is touched (no revoking by name).
        server.rows.append(Device(id: "row-hand", name: "Anna's iPhone", createdAt: 0, lastSeenAt: nil, current: false, platform: nil))
        let offline = AccessFakeDaemon(UUID())

        // The phone is gone from /me: removed from another device, by itself, or by an account reset.
        let after = responder(without: ["phone"], sync: sync, ledger: ledger)
        let outcome = try await after.run(servers: [server, offline])

        #expect(outcome.revoked == 1)
        #expect(server.rows.map(\.id).sorted() == ["row-hand", "row-me"])
        #expect(ledger.issues.isEmpty)
        #expect(sync.payload?.accessGrants.isEmpty == true, "its grant leaves the blob too")
    }

    @Test func aDeviceThatIsNoLongerApprovedLosesItsRowsToo() async throws {
        let (_, sync, server, ledger) = try await answeredRig()
        let after = responder(without: ["phone"], sync: sync, ledger: ledger, approvedOnly: true)
        let outcome = try await after.run(servers: [server])
        #expect(outcome.revoked == 1 && !server.rows.map(\.id).contains("row-1"))
    }

    @Test func aServerThatIsOfflineIsCleanedWhenItComesBack() async throws {
        let (_, sync, server, ledger) = try await answeredRig()
        let after = responder(without: ["phone"], sync: sync, ledger: ledger)
        server.isReachable = false
        #expect(try await after.run(servers: [server]).revoked == 0)
        #expect(server.rows.map(\.id).contains("row-1"), "nothing could be revoked")
        #expect(ledger.issues.count == 1, "the ledger keeps the id for later")
        server.isReachable = true
        #expect(try await after.run(servers: [server]).revoked == 1)
        #expect(!server.rows.map(\.id).contains("row-1") && ledger.issues.isEmpty)
    }

    @Test func aMacNeverRevokesARowItDidNotIssue() async throws {
        // Another Mac issued row-x for the phone; this Mac's ledger knows nothing of it.
        let sync = AccessFakeSync(blobWithServer())
        let (_, _, _, ledger) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)
        server.rows.append(Device(id: "row-x", name: "Anna's iPhone", createdAt: 0, lastSeenAt: nil, current: false, platform: nil))
        let after = responder(without: ["phone"], sync: sync, ledger: ledger)
        #expect(try await after.run(servers: [server]).revoked == 0)
        #expect(server.rows.map(\.id).contains("row-x"))
    }

    @Test func aRequestIsNotAnsweredWithoutTheAccountListingTheKey() async throws {
        let sync = AccessFakeSync(blobWithServer())
        // An older account service: /me lists no keys.
        let (responder, requester, _, _) = suite(sync: sync, devices: devices(keys: false))
        _ = try await requester.run()
        let server = AccessFakeDaemon(serverID)
        let outcome = try await responder.run(servers: [server])
        #expect(outcome.updateNeeded == 1 && outcome.issued == 0 && server.issuedCalls.isEmpty)
        #expect(sync.payload?.accessRequests.count == 1, "the request waits")
    }

    @Test func aRequestWithoutAKeyOfItsOwnIsNotAnswered() async throws {
        var payload = blobWithServer()
        payload.accessRequests = [
            AccessRequest(deviceID: "phone", serverID: serverID.uuidString, noiseKey: "k", publicKey: nil, at: Int64(now.timeIntervalSince1970 * 1000))
        ]
        let (responder, _, _, _) = suite(sync: AccessFakeSync(payload))
        let server = AccessFakeDaemon(serverID)
        let outcome = try await responder.run(servers: [server])
        #expect(outcome.failed == 1 && server.issuedCalls.isEmpty)
    }

    @Test func oneDeviceAndServerGetOneIssueInTenMinutes() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let clock = Clock(now)
        let ledger = AccessLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let list = devices()
        let responder = AccessResponder(
            sync: sync, account: AccessFakeAccount(deviceID: "mac", devices: list), identity: mac, ledger: ledger,
            now: { clock.value })
        let requester = AccessRequester(
            sync: sync, account: AccessFakeAccount(deviceID: "phone", devices: list), identity: phone,
            sink: AccessFakeSink(), noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()),
            defaults: UserDefaults(suiteName: UUID().uuidString)!, now: { clock.value })
        let server = AccessFakeDaemon(serverID)
        _ = try await requester.run()
        _ = try await responder.run(servers: [server])
        #expect(server.issuedCalls.count == 1)

        // The grant is lost and the phone asks again two minutes later: it has to wait.
        clock.value = clock.value.addingTimeInterval(120)
        sync.payload?.accessGrants = []
        _ = try await requester.run()
        let early = try await responder.run(servers: [server])
        #expect(early.cooledDown == 1 && server.issuedCalls.count == 1)
        #expect(sync.payload?.accessRequests.count == 1)

        clock.value = clock.value.addingTimeInterval(600)
        let later = try await responder.run(servers: [server])
        #expect(later.issued == 1 && server.issuedCalls.count == 2)
        #expect(!server.rows.map(\.id).contains("row-1"), "the first row is replaced")
    }

    @Test func aRequestAnotherMacAnsweredFirstIsSkippedBeforeAnythingIsIssued() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, _, _) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)
        _ = try await requester.run()
        // Between this Mac's first read and its second one, the other Mac writes its grant.
        let request = try #require(sync.payload?.accessRequests.first)
        sync.afterPulls = (sync.pulls + 2, {
            sync.payload?.accessRequests = []
            sync.payload?.accessGrants = [AccessGrant(deviceID: "phone", serverID: request.serverID, sealed: "other", at: request.at + 1)]
        })
        let outcome = try await responder.run(servers: [server])
        #expect(outcome.issued == 0 && outcome.answeredElsewhere == 1 && server.issuedCalls.isEmpty)
    }

    @Test func aGrantThatLostTheRaceRevokesTheRowJustIssued() async throws {
        let sync = AccessFakeSync(blobWithServer())
        let (responder, requester, _, ledger) = suite(sync: sync)
        let server = AccessFakeDaemon(serverID)
        _ = try await requester.run()
        let request = try #require(sync.payload?.accessRequests.first)
        // The other Mac's grant lands after this Mac's second read, just before its write.
        sync.beforeUpdate = {
            sync.payload?.accessGrants = [AccessGrant(deviceID: "phone", serverID: request.serverID, sealed: "other", at: request.at + 5)]
        }
        let outcome = try await responder.run(servers: [server])

        #expect(server.issuedCalls.count == 1)
        #expect(sync.payload?.accessGrants.map(\.sealed) == ["other"], "the other grant stands")
        #expect(!server.rows.map(\.id).contains("row-1"), "our row is revoked at once")
        #expect(ledger.issues.isEmpty)
        #expect(outcome.issued == 0 && outcome.answeredElsewhere == 1)
        #expect(sync.payload?.accessRequests.isEmpty == true)
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
