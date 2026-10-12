import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The paired servers: their records in UserDefaults, their tokens in a Keychain (faked here), and the disconnect rule.
@MainActor
@Suite struct ConnectedServersTests {
    private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "dev.bandito.ios.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func sample(_ name: String = "Forge box") -> ConnectedServer {
        ConnectedServer(id: UUID(), name: name, transport: .tailscale, isOnline: true)
    }

    @Test func disconnectRemovesTheRecordAndItsToken() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let store = ConnectedServers(defaults: defaults, secrets: secrets)
        let server = sample()
        let account = ConnectedServers.tokenAccount(for: server.id)
        try store.add(server, token: Data("token".utf8))
        #expect(try secrets.load(account: account) == Data("token".utf8))

        try store.disconnect(server.id)

        #expect(store.servers.isEmpty)
        #expect(try secrets.load(account: account) == nil)
        #expect(ConnectedServers(defaults: defaults, secrets: secrets).servers.isEmpty)
    }

    @Test func aRefusedKeychainKeepsTheServerAndItsToken() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let store = ConnectedServers(defaults: defaults, secrets: secrets)
        let server = sample()
        let account = ConnectedServers.tokenAccount(for: server.id)
        try store.add(server, token: Data("token".utf8))
        secrets.refuseWrites(.keychain(-25300))

        #expect(throws: SecretStoreError.keychain(-25300)) {
            try store.disconnect(server.id)
        }

        #expect(store.servers == [server])
        #expect(try secrets.load(account: account) == Data("token".utf8))
    }

    @Test func recordsSurviveARelaunchWithoutTheirTokenInDefaults() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        let server = sample("Office")
        try ConnectedServers(defaults: defaults, secrets: secrets).add(server, token: Data("token".utf8))

        let relaunched = ConnectedServers(defaults: defaults, secrets: secrets)
        #expect(relaunched.servers == [server])
        let stored = defaults.data(forKey: ConnectedServers.recordsKey) ?? Data()
        #expect(!String(decoding: stored, as: UTF8.self).contains("token"))
    }

    @Test func everyServerHasItsOwnTokenAccount() {
        let first = UUID()
        let second = UUID()
        #expect(ConnectedServers.tokenAccount(for: first) != ConnectedServers.tokenAccount(for: second))
    }

    @Test func theDemoServerIsOnlineAndNeedsNoKeychain() {
        let demo = ConnectedServers.launch(demo: true)
        #expect(demo.servers.map(\.id) == [IOSDemo.serverID])
        #expect(demo.servers.first?.isOnline == true)
    }
}
