import BanditoKit
import Foundation

/// Where an access that another device of the account issued for this Mac ends up: the server is added to the Mac's list
/// (the same path as a server added by hand), with the device token and the relay key in the Keychain, and connects at once.
@MainActor
final class MacAccessSink: ServerAccessSink, @unchecked Sendable {
    private let app: () -> AppModel?
    private let noiseKeys: ServerNoiseKeyStore
    /// The phone records of this Mac's own servers (what it publishes), to tell that a server of the account is one it has.
    private let ownRecords: () -> [UUID: SyncedPhone]

    init(app: @escaping () -> AppModel?, noiseKeys: ServerNoiseKeyStore, ownRecords: @escaping () -> [UUID: SyncedPhone]) {
        self.app = app
        self.noiseKeys = noiseKeys
        self.ownRecords = ownRecords
    }

    func hasAccess(serverID: UUID) async -> Bool {
        app()?.servers.contains { $0.id == serverID } ?? false
    }

    func hasAccess(serverID: UUID, phone: SyncedPhone?) async -> Bool {
        guard let app = app() else { return false }
        if app.servers.contains(where: { $0.id == serverID }) { return true }
        guard let phone else { return false }
        if app.servers.contains(where: { phone.isSameDaemon(as: $0.config.endpoint) }) { return true }
        // An ssh server of this Mac whose daemon says how a phone reaches it: the same daemon the account lists.
        return ownRecords().values.contains { phone.isSameDaemon(as: $0) }
    }

    func receive(_ access: ServerAccess) async throws {
        guard let app = app() else { throw MacAccessError.notReady }
        let key = try noiseKeys.privateKey(for: access.serverID)
        guard let config = access.serverConfig(noiseKey: key) else { throw MacAccessError.noWayIn }
        if app.servers.contains(where: { $0.id == config.id }) { return }
        app.add(config)
        // `add` refuses a server whose token or key the Keychain would not keep: then the grant waits for the next cycle.
        guard app.servers.contains(where: { $0.id == config.id }) else { throw MacAccessError.notSaved }
    }
}

enum MacAccessError: Error {
    case notReady, noWayIn, notSaved
}
