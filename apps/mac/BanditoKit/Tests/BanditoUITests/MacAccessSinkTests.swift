@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Which servers of the account this Mac counts as its own, so it asks only for the ones it lacks.
@MainActor
@Suite struct MacAccessSinkTests {
    static let sid = "abcdefghijklmnopqrstuvwxyz"
    static let nk = Base64URL.encode(Data((0..<32).map { UInt8($0 + 1) }))
    let phone = SyncedPhone(sid: sid, relayHost: "relay.bandito.dev", nk: nk)

    func app(with configs: [ServerConfig]) -> (AppModel, UserDefaults, String) {
        let suite = "mac-access-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(try? JSONEncoder().encode(configs), forKey: "servers.v1")
        return (AppModel(defaults: defaults), defaults, suite)
    }

    @Test func aServerIsOwnByIdByTheSameDaemonOrByTheRecordOfOneOfItsSshServers() async {
        let own = ServerConfig(
            name: "Studio", endpoint: .reachable(hosts: [], fingerprint: nil, relay: RelayRoute(host: "relay.bandito.dev", sid: Self.sid), noiseKey: Self.nk))
        let ssh = ServerConfig(name: "vps", endpoint: .ssh(server: SSHServerAddress(host: "h"), remotePort: 7878))
        let (model, _, suite) = app(with: [own, ssh])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let sshRecord = SyncedPhone(sid: "zzzzzzzzzzzzzzzzzzzzzzzzzz", relayHost: "relay.bandito.dev", nk: Base64URL.encode(Data(repeating: 8, count: 32)))
        let sink = MacAccessSink(
            app: { model }, noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()), ownRecords: { [ssh.id: sshRecord] })
        #expect(await sink.hasAccess(serverID: own.id))
        #expect(await sink.hasAccess(serverID: UUID(), phone: phone), "the same daemon under another id")
        #expect(await sink.hasAccess(serverID: UUID(), phone: sshRecord), "the daemon of an ssh server of this Mac")
        #expect(await sink.hasAccess(serverID: UUID(), phone: SyncedPhone(sid: Self.sid, relayHost: "r", nk: Base64URL.encode(Data(repeating: 3, count: 32)))) == false)
        #expect(await sink.hasAccess(serverID: UUID()) == false)
    }

    @Test func aRecordWithNoWayInIsRefusedAndNothingIsAdded() async {
        let (model, _, suite) = app(with: [])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let sink = MacAccessSink(app: { model }, noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()), ownRecords: { [:] })
        await #expect(throws: MacAccessError.self) {
            try await sink.receive(ServerAccess(serverID: UUID(), name: "x", phone: SyncedPhone(), deviceToken: "t"))
        }
        #expect(model.servers.isEmpty)
    }
}
