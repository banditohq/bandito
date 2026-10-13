import BanditoKit
import Foundation
import Observation
import UIKit

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
    /// Whether the saved list was read completely. Until then nothing is written (a list read in part would overwrite
    /// the rest): a read that cannot be done yet (the phone was not unlocked since its restart) is tried again.
    private(set) var loaded = false
    /// Servers whose disconnecting is under way (a second tap does nothing).
    private(set) var disconnecting: Set<UUID> = []
    @ObservationIgnored private var didReset = false
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?

    /// What the screens show: the demo world when there is one, else the paired servers.
    var current: [ServerModel] { demo.isEmpty ? servers : demo }

    /// The server the Crew screen shows. One for now: the first.
    var active: ServerModel? { current.first }

    /// Servers the person disconnected on purpose, by id. The account does not offer them again: without this a server
    /// disconnected here would come back with the next round of "servers follow you".
    static let dismissedKey = "servers.dismissed.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: ServerStore
    @ObservationIgnored private let secrets: SecretStore
    /// Connects a new model. Replaced in tests, so no network is touched.
    @ObservationIgnored private let connectOverride: (@MainActor (ServerModel) -> Void)?
    /// Asks a server to forget this device. Replaced in tests.
    /// Called when a new server has connected for the first time: the notification cursor starts at its tail.
    @ObservationIgnored var onFirstConnected: @MainActor (ServerModel) -> Void = { server in
        IOSNotifications.shared.cursor.baseline(for: server)
    }
    /// Called when a server is forgotten: its notification cursor goes too.
    @ObservationIgnored var forgetCursor: @MainActor (UUID) -> Void = { IOSNotifications.shared.cursor.forget(serverID: $0) }
    @ObservationIgnored var revokeSelf: @Sendable (ServerConfig) async -> Bool = { await DevicePairing.revokeSelf(config: $0) }

    init(
        store: ServerStore = ServerStore(), secrets: SecretStore = ServerSession.deviceSecrets(),
        connect: (@MainActor (ServerModel) -> Void)? = nil, defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.store = store
        self.secrets = secrets
        self.connectOverride = connect
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

    /// Reads the saved servers and connects them. A server whose token is missing is not connected: it would be refused
    /// anyway, and the person pairs it again. When the list or a token cannot be read yet (before the first unlock after
    /// a restart) the read stays open: the next call, and the moment the phone's data becomes available, read it again.
    func loadIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard !loaded else { return }
        if arguments.contains(Self.resetArgument), !didReset {
            didReset = true
            reset()
        }
        var complete = true
        switch store.read() {
        case .empty:
            break
        case .unavailable:
            complete = false
        case .unreadable:
            // Not a list: it stays as it is (the first save moves it aside), and the app starts with none.
            break
        case .configs(let configs, _):
            for config in configs where !servers.contains(where: { $0.id == config.id }) {
                let token: Data?
                do {
                    token = try secrets.load(account: config.id.uuidString)
                } catch {
                    complete = false
                    continue
                }
                guard let token, let text = String(data: token, encoding: .utf8), !text.isEmpty else { continue }
                var withToken = config
                withToken.token = text
                // The key this phone speaks to the relay with. Without it the relay cannot be used, direct addresses still can.
                if config.endpoint.relayPart != nil,
                    let key = (try? secrets.load(account: Self.noiseAccount(config.id))).flatMap({ $0 }),
                    let keyText = String(data: key, encoding: .utf8)
                {
                    withToken.noiseSecret = keyText
                }
                start(withToken)
            }
        }
        loaded = complete
        if !complete { waitForUnlock() }
    }

    /// Reads again when protected data becomes available (the first unlock).
    private func waitForUnlock() {
        guard unlockObserver == nil else { return }
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loadIfNeeded(arguments: [])
                if self.loaded, let observer = self.unlockObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.unlockObserver = nil
                }
            }
        }
    }

    /// Keeps a paired server: the token and the relay key first (a server that could not keep both is not kept at all, and
    /// a server paired again keeps its old token and key as they were), then the list. The same server paired again (every
    /// identifier it shares agrees: certificate, Noise key) keeps its place and its id, and gets the new token. Another
    /// server behind the same certificate or key is refused (`SessionError.differentServer`), never replaced.
    func add(_ config: ServerConfig) throws {
        guard let token = config.token, !token.isEmpty else { throw SessionError.noToken }
        // The saved list is read before it is written to; one that cannot be read yet is not written over.
        loadIfNeeded(arguments: [])
        guard loaded else { throw SessionError.notReady }
        var config = config
        var replaced: UUID?
        if servers.contains(where: { config.endpoint.conflicts(with: $0.config.endpoint) }) { throw SessionError.differentServer }
        if let same = servers.first(where: { config.endpoint.isSameServer(as: $0.config.endpoint) }) {
            config.id = same.id
            replaced = same.id
        }
        // The token and the key first. When the Keychain refuses either, both go back to what they were: a new token
        // with an old key (or a key without its token) would only fail later, and an old server stays as it was.
        let tokenAccount = config.id.uuidString
        let keyAccount = Self.noiseAccount(config.id)
        let oldToken = (try? secrets.load(account: tokenAccount)).flatMap { $0 }
        let oldKey = (try? secrets.load(account: keyAccount)).flatMap { $0 }
        do {
            try secrets.save(Data(token.utf8), account: tokenAccount)
            try secrets.save(config.noiseSecret.map { Data($0.utf8) }, account: keyAccount)
        } catch {
            try? secrets.save(oldToken, account: tokenAccount)
            try? secrets.save(oldKey, account: keyAccount)
            throw SessionError.keychain
        }
        if let replaced { drop(replaced) }
        if dismissed.contains(config.id) { setDismissed(dismissed.subtracting([config.id])) }
        start(config)
        save()
    }

    /// The ids the person disconnected on purpose.
    var dismissed: Set<UUID> {
        Set((defaults.stringArray(forKey: Self.dismissedKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func setDismissed(_ ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: Self.dismissedKey)
    }

    /// Whether this iPhone has the server `id` from the account, or the same daemon under another id, or the person
    /// disconnected it on purpose.
    func holds(serverID: UUID, phone: SyncedPhone?) -> Bool {
        if servers.contains(where: { $0.id == serverID }) || dismissed.contains(serverID) { return true }
        guard let phone else { return false }
        return servers.contains { phone.isSameDaemon(as: $0.config.endpoint) }
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
        /// Already being disconnected.
        case busy
    }

    /// Disconnects a server. The token is removed first (when the Keychain refuses, nothing else happens), then the model
    /// is disconnected (so it does not retry with a token that is about to be revoked), then the server is asked to
    /// forget this device (best effort, it may be off), and last the record, the remembered address and the notification
    /// cursor go.
    func disconnect(_ id: UUID) async -> Disconnected {
        guard !disconnecting.contains(id) else { return .busy }
        guard let server = servers.first(where: { $0.id == id }) else { return .unknown }
        disconnecting.insert(id)
        defer { disconnecting.remove(id) }
        let config = server.config
        var withToken = config
        withToken.token = (try? secrets.load(account: id.uuidString)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
        withToken.noiseSecret = (try? secrets.load(account: Self.noiseAccount(id))).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
        do {
            try secrets.save(nil, account: id.uuidString)
        } catch {
            return .keychainRefused
        }
        try? secrets.save(nil, account: Self.noiseAccount(id))
        await server.disconnect()
        var revoked = false
        if config.endpoint.isPaired { revoked = await revokeSelf(withToken) }
        if let fingerprint = config.endpoint.pinnedFingerprint { DirectHostMemory.shared.forget(fingerprint) }
        drop(id)
        setDismissed(dismissed.union([id]))
        forgetCursor(id)
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
        try? secrets.save(nil, account: Self.noiseAccount(id))
        setDismissed(dismissed.union([id]))
        forgetCursor(id)
        // What was written to this server and not sent stays with it no longer.
        ChatOutbox.shared.forget(serverID: id)
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
        for config in store.load() {
            try? secrets.save(nil, account: config.id.uuidString)
            try? secrets.save(nil, account: Self.noiseAccount(config.id))
        }
        for server in servers {
            ChatOutbox.shared.forget(serverID: server.id)
            Task { await server.disconnect() }
        }
        servers = []
        store.clear()
    }

    enum SessionError: Error, Equatable {
        case noToken
        /// The Keychain refused the token.
        case keychain
        /// Another server already here has the same certificate (or key) but not the same other identifier.
        case differentServer
        /// The saved list could not be read yet (the phone is locked since its restart).
        case notReady
    }

    private func start(_ config: ServerConfig) {
        let model = ServerModel(config: config)
        servers.append(model)
        if let connectOverride {
            connectOverride(model)
        } else {
            Task { @MainActor in
                await model.connect()
                onFirstConnected(model)
            }
        }
    }

    private func save() {
        // Before the saved list was read completely, writing would drop what was not read.
        guard loaded else { return }
        store.save(servers.map(\.config))
    }

    /// The Keychain account of a server's relay key, next to the token's (`<id>`).
    static func noiseAccount(_ id: UUID) -> String { "\(id.uuidString).noise" }
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
