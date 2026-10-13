@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// A server the person removes on this Mac is not brought back by the account, until they show it.
@MainActor
@Suite struct HiddenServersTests {
    static let route = RelayRoute(host: "relay.bandito.dev", sid: "abcdefghijklmnopqrstuvwxyz")
    static let nk = Base64URL.encode(Data((0..<32).map { UInt8($0 + 1) }))

    func hub() -> (AccountHub, DismissedServers) {
        let keys = MemorySecretStore()
        let session = Session(
            token: "t", user: AccountUser(id: "u1", email: "a@example.com", name: nil, githubLogin: nil),
            device: DeviceRef(id: "mac", approved: true))
        try? keys.save(try? JSONEncoder().encode(session), account: AccountClient.sessionAccount)
        let dismissed = DismissedServers(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let hub = AccountHub(keys: keys, dismissed: dismissed, loadIdentity: { throw URLError(.notConnectedToInternet) })
        hub.me = Me(
            user: AccountUser(id: "u1", email: "a@example.com", name: nil, githubLogin: nil),
            device: DeviceRef(id: "mac", approved: true), devices: [])
        return (hub, dismissed)
    }

    func config(_ id: UUID = UUID()) -> ServerConfig {
        ServerConfig(
            id: id, name: "Studio", endpoint: .reachable(hosts: [], fingerprint: nil, relay: Self.route, noiseKey: Self.nk))
    }

    @Test func removingAServerHidesItAndAddingTheSameDaemonLiftsTheMark() {
        let (hub, dismissed) = hub()
        let removed = config()
        hub.dismiss(removed)
        #expect(hub.hiddenServerCount == 1)
        let phone = SyncedPhone(endpoint: removed.endpoint)
        #expect(dismissed.contains(accountID: "u1", serverID: removed.id, phone: nil))
        #expect(dismissed.contains(accountID: "u1", serverID: UUID(), phone: phone))
        // The same daemon added again under another id.
        hub.lift(config())
        #expect(hub.hiddenServerCount == 0)
    }

    @Test func showingHiddenServersClearsThemAndSignedOutNothingIsKept() {
        let (hub, dismissed) = hub()
        hub.dismiss(config())
        hub.showHiddenServers()
        #expect(hub.hiddenServerCount == 0 && dismissed.count(accountID: "u1") == 0)
        // Without a session nothing is recorded.
        let signedOut = AccountHub(
            keys: MemorySecretStore(), dismissed: dismissed, loadIdentity: { throw URLError(.notConnectedToInternet) })
        signedOut.dismiss(config())
        #expect(dismissed.count(accountID: "u1") == 0)
    }

    @Test func theAppTellsTheAccountWhenThePersonRemovesAServerButNotWhenItReplacesOne() {
        let suite = "hidden-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let one = ServerConfig(name: "vps", endpoint: .ssh(server: SSHServerAddress(host: "h"), remotePort: 7878))
        defaults.set(try? JSONEncoder().encode([one]), forKey: "servers.v1")
        let app = AppModel(defaults: defaults)
        var forgotten: [UUID] = []
        app.onServerForgotten = { forgotten.append($0.id) }
        app.remove(one.id)
        #expect(forgotten.isEmpty, "an internal removal is not the person's choice")
        defaults.set(try? JSONEncoder().encode([one]), forKey: "servers.v1")
        let again = AppModel(defaults: defaults)
        again.onServerForgotten = { forgotten.append($0.id) }
        again.forget(one.id)
        #expect(forgotten == [one.id] && again.servers.isEmpty)
    }
}
