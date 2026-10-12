import BanditoKit
import Foundation
import Observation

/// The servers this iPhone is connected to: the saved list (`servers.v1`, without tokens), the device tokens in the
/// Keychain (one item per server, readable after the first unlock, never copied to another device), and a live
/// `ServerModel` for each.
@MainActor
@Observable
final class ServerSession {
    /// The one session of the app: the views, the notifications and the background check all use it.
    static let shared = ServerSession()

    /// The launch argument that forgets every saved server first (UI tests start from nothing).
    static let resetArgument = "-resetServers"
    static let keychainService = "dev.bandito.ios.server-token"

    /// The servers this iPhone is paired with.
    private(set) var servers: [ServerModel] = []
    /// The servers of the `-demo` launch (nothing is saved for them). Empty otherwise.
    private(set) var demo: [ServerModel] = []
    private(set) var loaded = false

    /// What the screens show: the demo world when there is one, else the paired servers.
    var current: [ServerModel] { demo.isEmpty ? servers : demo }

    /// The server the Crew screen shows. One for now: the first.
    var active: ServerModel? { current.first }

    @ObservationIgnored private let store: ServerStore
    @ObservationIgnored private let secrets: SecretStore
    /// Connects a new model. Replaced in tests, so no network is touched.
    @ObservationIgnored private let connect: @MainActor (ServerModel) -> Void
    /// Asks a server to forget this device. Replaced in tests.
    @ObservationIgnored var revokeSelf: @Sendable (ServerConfig) async -> Bool = { await DevicePairing.revokeSelf(config: $0) }

    init(
        store: ServerStore = ServerStore(), secrets: SecretStore = ServerSession.deviceSecrets(),
        connect: @escaping @MainActor (ServerModel) -> Void = { model in Task { await model.connect() } }
    ) {
        self.store = store
        self.secrets = secrets
        self.connect = connect
    }

    /// Where device tokens are kept: the Keychain. On the Simulator an unsigned build (the project builds that way) has
    /// no Keychain access group and the Keychain refuses every write, so there a private file stands in
    /// (`SimulatorSecretStore`). A device never falls back to a file.
    static func deviceSecrets() -> SecretStore {
        let keychain = KeychainStore(service: keychainService)
        #if targetEnvironment(simulator)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return SimulatorSecretStore(
            primary: keychain, fallback: FileSecretStore(directory: base.appending(path: "Bandito/simulator-secrets")))
        #else
        return keychain
        #endif
    }

    /// Reads the saved servers and connects them. Once. A server whose token is missing is not connected: it would be
    /// refused anyway, and the person pairs it again.
    func loadIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard !loaded else { return }
        loaded = true
        if arguments.contains(Self.resetArgument) { reset() }
        for config in store.load() {
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

    /// Renames a server. The name is cleaned like every name (`ServerNameRules`); one with nothing left changes nothing.
    func rename(_ id: UUID, to name: String) {
        let cleaned = ServerNameRules.clean(name)
        guard !cleaned.isEmpty, let server = servers.first(where: { $0.id == id }) else { return }
        server.changeConfig { $0.name = cleaned }
        save()
    }

    /// What disconnecting a server came to.
    enum Disconnected: Equatable {
        /// Gone from this iPhone; `revokedOnServer` says whether the server was reached and forgot this device too.
        case removed(revokedOnServer: Bool)
        /// The Keychain refused to give up the token: nothing changed.
        case keychainRefused
        /// No such server here (a demo server).
        case unknown
    }

    /// Disconnects a server: asks it to forget this device (best effort, it may be off), then removes the token, the
    /// record and the remembered address. The token goes first of the local steps: when the Keychain refuses, nothing
    /// is removed.
    func disconnect(_ id: UUID) async -> Disconnected {
        guard let server = servers.first(where: { $0.id == id }) else { return .unknown }
        let config = server.config
        var revoked = false
        if case .direct = config.endpoint {
            var withToken = config
            withToken.token = (try? secrets.load(account: id.uuidString)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
            revoked = await revokeSelf(withToken)
        }
        do {
            try secrets.save(nil, account: id.uuidString)
        } catch {
            return .keychainRefused
        }
        if case .direct(_, let fingerprint) = config.endpoint { DirectHostMemory.shared.forget(fingerprint) }
        drop(id)
        save()
        return .removed(revokedOnServer: revoked)
    }

    /// Shows the demo world's servers (the `-demo` launch). They are not saved and not connected here.
    func installDemo(_ models: [ServerModel]) {
        demo = models
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
        for config in store.load() { try? secrets.save(nil, account: config.id.uuidString) }
        for server in servers { Task { await server.disconnect() } }
        servers = []
        store.clear()
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

    private func save() {
        store.save(servers.map(\.config))
    }

    private static func fingerprint(of config: ServerConfig) -> String? {
        if case .direct(_, let fingerprint) = config.endpoint { return fingerprint }
        return nil
    }
}

#if targetEnvironment(simulator)
/// The Keychain first; when an unsigned Simulator build is refused (`errSecMissingEntitlement`, -34018), a private file.
struct SimulatorSecretStore: SecretStore {
    let primary: SecretStore
    let fallback: SecretStore

    func load(account: String) throws -> Data? {
        if let data = try? primary.load(account: account) { return data }
        return try fallback.load(account: account)
    }

    func save(_ data: Data?, account: String) throws {
        do {
            try primary.save(data, account: account)
            if data == nil { try? fallback.save(nil, account: account) }
        } catch SecretStoreError.keychain(let status) where status == errSecMissingEntitlement {
            try fallback.save(data, account: account)
        }
    }
}
#endif
