import Foundation
import Testing

@testable import BanditoKit

@MainActor
@Suite struct DismissedServersTests {
    let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    let record = SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK")

    func store() -> DismissedServers { DismissedServers(defaults: UserDefaults(suiteName: UUID().uuidString)!) }

    @Test func aHiddenServerIsKnownByIdOrAsTheSameDaemonAndLiftsTheSameWay() {
        let hidden = store()
        #expect(hidden.count(accountID: "u1") == 0)
        hidden.insert(accountID: "u1", serverID: serverID, phone: record)
        #expect(hidden.count(accountID: "u1") == 1)
        #expect(hidden.contains(accountID: "u1", serverID: serverID, phone: nil))
        #expect(hidden.contains(accountID: "u1", serverID: UUID(), phone: record), "the same daemon under another id")
        #expect(!hidden.contains(accountID: "u1", serverID: UUID(), phone: SyncedPhone(sid: "S2", relayHost: "r", nk: "OTHER")))
        // Another account has its own list.
        #expect(!hidden.contains(accountID: "u2", serverID: serverID, phone: record))
        // Hiding again does not duplicate; adding the daemon back by another id lifts the mark.
        hidden.insert(accountID: "u1", serverID: serverID, phone: record)
        #expect(hidden.count(accountID: "u1") == 1)
        hidden.lift(accountID: "u1", serverID: UUID(), phone: record)
        #expect(hidden.count(accountID: "u1") == 0)
        hidden.insert(accountID: "u1", serverID: serverID, phone: nil)
        hidden.clear(accountID: "u1")
        #expect(hidden.count(accountID: "u1") == 0)
    }

    @Test func aHiddenServerIsNotAskedForAndComesBackWhenShown() async throws {
        let sync = AccessFakeSync(
            SyncPayload(servers: [
                SyncedServer(id: serverID, name: "vps", endpoint: .ssh(host: "h", user: nil, port: nil), addedAt: 1, phone: record)
            ]))
        let mac = try makeIdentity(), phone = try makeIdentity()
        let devices = [
            AccountDevice(id: "mac", name: "Studio", platform: "macos", approved: true, publicKey: mac.publicKeyBase64),
            AccountDevice(id: "phone", name: "iPhone", platform: "ios", approved: true, publicKey: phone.publicKeyBase64),
        ]
        let hidden = store()
        hidden.insert(accountID: "u1", serverID: serverID, phone: nil)
        let requester = AccessRequester(
            sync: sync, account: AccessFakeAccount(deviceID: "phone", devices: devices), identity: phone, sink: AccessFakeSink(),
            noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()), defaults: UserDefaults(suiteName: UUID().uuidString)!,
            dismissed: hidden)
        var states = try await requester.run()
        #expect(states.map(\.status) == [.hidden])
        #expect(sync.payload?.accessRequests.isEmpty == true && sync.updates == 0, "nothing asked, nothing written")
        // Shown again: the next cycle asks.
        hidden.clear(accountID: "u1")
        states = try await requester.run()
        #expect(states.map(\.status) == [.waitingForMac])
        #expect(sync.payload?.accessRequests.count == 1)
        // A request left from before is removed once the server is hidden.
        hidden.insert(accountID: "u1", serverID: serverID, phone: nil)
        _ = try await requester.run()
        #expect(sync.payload?.accessRequests.isEmpty == true)
    }
}
