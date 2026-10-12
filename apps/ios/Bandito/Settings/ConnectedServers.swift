import BanditoKit
import Foundation
import Observation

/// How this iPhone reaches a paired server.
enum ServerTransport: String, Codable, Sendable {
    case tailscale
    case lan
}

/// A server this iPhone is paired with. The device token is not in here: it is in the Keychain, under
/// `ConnectedServers.tokenAccount(for:)`.
struct ConnectedServer: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var transport: ServerTransport
    var isOnline: Bool
}

/// The servers this iPhone is paired with. Records are kept in UserDefaults, each device token in the Keychain.
@MainActor
@Observable
final class ConnectedServers {
    static let recordsKey = "ios.servers.paired"
    static let keychainService = "dev.bandito.ios.servers"
    private static let demoSuite = "dev.bandito.ios.demo"

    private(set) var servers: [ConnectedServer]
    private let defaults: UserDefaults
    private let secrets: any SecretStore

    init(defaults: UserDefaults, secrets: any SecretStore) {
        self.defaults = defaults
        self.secrets = secrets
        servers = Self.load(from: defaults)
    }

    /// The servers of a launch: the demo server with `-demo` (nothing touches the Keychain), otherwise the real ones.
    static func launch(demo: Bool) -> ConnectedServers {
        demo ? demoServers() : ConnectedServers(defaults: .standard, secrets: KeychainStore(service: keychainService))
    }

    /// The Keychain account that holds one server's device token.
    static func tokenAccount(for id: UUID) -> String {
        "device-token.\(id.uuidString)"
    }

    /// Stores a server and its token. Pairing writes through this; nothing else does.
    func add(_ server: ConnectedServer, token: Data) throws {
        try secrets.save(token, account: Self.tokenAccount(for: server.id))
        servers.removeAll { $0.id == server.id }
        servers.append(server)
        persist()
    }

    /// Removes a server: its token from the Keychain first, then the record. When the Keychain refuses, nothing changes.
    func disconnect(_ id: UUID) throws {
        try secrets.save(nil, account: Self.tokenAccount(for: id))
        servers.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(servers), forKey: Self.recordsKey)
    }

    private static func load(from defaults: UserDefaults) -> [ConnectedServer] {
        guard let data = defaults.data(forKey: recordsKey) else { return [] }
        return (try? JSONDecoder().decode([ConnectedServer].self, from: data)) ?? []
    }

    private static func demoServers() -> ConnectedServers {
        // The suite name is a constant string, so the optional cannot be nil.
        let defaults = UserDefaults(suiteName: demoSuite)!
        defaults.removePersistentDomain(forName: demoSuite)
        let store = ConnectedServers(defaults: defaults, secrets: InMemorySecretStore())
        try? store.add(
            ConnectedServer(id: IOSDemo.serverID, name: "Demo", transport: .lan, isOnline: true),
            token: Data("demo".utf8))
        return store
    }
}
