import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@MainActor
@Suite struct AccountAccessSyncTests {
    private let phone = SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK")

    @Test func aServerWithRelayOrDirectAccessCarriesItsPhoneRecord() {
        let ssh = ServerConfig(name: "prod", endpoint: .ssh(target: "deploy@prod.example", remotePort: 7878))
        let plain = ServerConfig(name: "dev", endpoint: .ssh(target: "dev.example", remotePort: 7878))
        let payload = ServerSyncPayload.payload(for: [ssh, plain], phones: [ssh.id: phone])
        #expect(payload.servers.first { $0.name == "prod" }?.phone == phone)
        #expect(payload.servers.first { $0.name == "dev" }?.phone == nil)
    }

    @Test func theLocalDaemonIsSyncedOnlyWithAPhoneRecordAndThisMacsAccountId() {
        let local = ServerConfig(name: "This Mac", endpoint: .local(socketPath: "/tmp/bandito.sock"))
        #expect(ServerSyncPayload.payload(for: [local], phones: [local.id: phone]).servers.isEmpty)
        #expect(ServerSyncPayload.payload(for: [local], localDeviceID: "mac-1").servers.isEmpty)
        let both = ServerSyncPayload.payload(for: [local], phones: [local.id: phone], localDeviceID: "mac-1")
        #expect(both.servers.first?.endpoint == .local(deviceID: "mac-1"))
        #expect(both.servers.first?.phone == phone)
    }

    @Test func aPublishKeepsThePhoneRecordAndTheRequestsAnotherDeviceWrote() {
        let ssh = ServerConfig(name: "prod", endpoint: .ssh(target: "prod.example", remotePort: 7878))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var remote = ServerSyncPayload.payload(for: [ssh], phones: [ssh.id: phone])
        remote.accessRequests = [AccessRequest(deviceID: "phone", serverID: ssh.id.uuidString, noiseKey: "k", at: now)]
        // A Mac that could not read the record this time publishes without it.
        let merged = ServerSyncPayload.merge(local: ServerSyncPayload.payload(for: [ssh]), remote: remote)
        #expect(merged.servers.first?.phone == phone)
        #expect(merged.accessRequests.count == 1)
    }
}
