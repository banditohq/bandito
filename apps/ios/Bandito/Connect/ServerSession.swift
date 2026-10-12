import BanditoKit
import Foundation
import Observation

/// The servers this iPhone is connected to: the saved list (`servers.v1`, without tokens), the device tokens in the
/// Keychain (one item per server, readable after the first unlock, never copied to another device), and a live
/// `ServerModel` for each.
@MainActor
@Observable
final class ServerSession {
    /// The launch argument that forgets every saved server first (UI tests start from nothing).
    static let resetArgument = "-resetServers"
    static let configsKey = "servers.v1"
    static let keychainService = "dev.bandito.ios.server-token"

    private(set) var servers: [ServerModel] = []
    private(set) var loaded = false

    /// The server the Crew screen shows. One for now: the first.
    var active: ServerModel? { servers.first }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStore
    /// Connects a new model. Replaced in tests, so no network is touched.
    @ObservationIgnored private let connect: @MainActor (ServerModel) -> Void

    init(
        defaults: UserDefaults = .standard, secrets: SecretStore = KeychainStore(service: ServerSession.keychainService),
        connect: @escaping @MainActor (ServerModel) -> Void = { model in Task { await model.connect() } }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.connect = connect
    }

    /// Reads the saved servers and connects them. Once. A server whose token is missing is not connected: it would be
    /// refused anyway, and the person pairs it again.
    func loadIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard !loaded else { return }
        loaded = true
        if arguments.contains(Self.resetArgument) { reset() }
        for config in savedConfigs() {
            guard let token = (try? secrets.load(account: config.id.uuidString)).flatMap({ $0 }).flatMap({ String(data: $0, encoding: .utf8) }),
                !token.isEmpty
            else { continue }
            var withToken = config
            withToken.token = token
            start(withToken)
        }
    }

    /// Keeps a paired server: the token first (a server that could not keep its key is not kept at all), then the
    /// list. A server with the same certificate is the same server paired again: it keeps its place and its id, and
    /// gets the new token.
    func add(_ config: ServerConfig) throws {
        guard let token = config.token, !token.isEmpty else { throw SessionError.noToken }
        var config = config
        var replaced: UUID?
        if case .direct(_, let fingerprint) = config.endpoint,
            let same = servers.first(where: { Self.fingerprint(of: $0.config) == fingerprint })
        {
            config.id = same.id
            replaced = same.id
        }
        // The token first: when the Keychain refuses it, nothing else changes (an old server stays as it was).
        do {
            try secrets.save(Data(token.utf8), account: config.id.uuidString)
        } catch {
            throw SessionError.keychain
        }
        if let replaced { drop(replaced) }
        start(config)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let server = servers.first(where: { $0.id == id }) else { return }
        server.changeConfig { $0.name = String(trimmed.prefix(64)) }
        save()
    }

    /// Forgets a server and its key on this iPhone. (The daemon keeps the device until it is disconnected there.)
    func remove(_ id: UUID) {
        guard drop(id) else { return }
        try? secrets.save(nil, account: id.uuidString)
        save()
    }

    /// Takes the model out of the list and disconnects it. The key and the saved list stay for the caller to settle.
    @discardableResult
    private func drop(_ id: UUID) -> Bool {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return false }
        let server = servers.remove(at: index)
        Task { await server.disconnect() }
        return true
    }

    /// Forgets everything.
    func reset() {
        for config in savedConfigs() { try? secrets.save(nil, account: config.id.uuidString) }
        for server in servers { Task { await server.disconnect() } }
        servers = []
        defaults.removeObject(forKey: Self.configsKey)
    }

    enum SessionError: Error, Equatable {
        case noToken
        /// The Keychain refused the token.
        case keychain
    }

    private func start(_ config: ServerConfig) {
        let model = ServerModel(config: config)
        servers.append(model)
        connect(model)
    }

    private func savedConfigs() -> [ServerConfig] {
        guard let data = defaults.data(forKey: Self.configsKey) else { return [] }
        return (try? JSONDecoder().decode([ServerConfig].self, from: data)) ?? []
    }

    private func save() {
        let configs = servers.map(\.config)
        defaults.set(try? JSONEncoder().encode(configs), forKey: Self.configsKey)
    }

    private static func fingerprint(of config: ServerConfig) -> String? {
        if case .direct(_, let fingerprint) = config.endpoint { return fingerprint }
        return nil
    }
}
