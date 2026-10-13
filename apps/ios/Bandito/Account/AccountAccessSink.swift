import BanditoKit
import Foundation

/// One access this iPhone received from another device of the account: the server as the account knows it, and how to
/// reach it. The device token itself is in the secret store, never in this record.
struct ReceivedAccess: Codable, Equatable, Sendable {
    var serverID: UUID
    var name: String
    var phone: SyncedPhone
    var receivedAt: Date
}

/// What the sink needs from the list of servers of this iPhone (`ServerSession`): to add the server an access makes
/// (the same path as after a scanned QR code: token and relay key into the Keychain, saved, connected at once), and to
/// say whether the iPhone has a server already.
struct AccessSession: Sendable {
    /// Adds the server; throws when it could not be kept (the Keychain refused, the list is not readable yet, another
    /// server has the same certificate).
    var add: @MainActor @Sendable (ServerConfig) throws -> Void
    /// Whether the iPhone has the server `id`, or the same daemon under another id (`SyncedPhone.isSameDaemon`), or the
    /// person disconnected it on purpose (it is not asked for again).
    var holds: @MainActor @Sendable (UUID, SyncedPhone?) -> Bool
}

/// Keeps what the account hands this iPhone. With a `session` the server goes straight into the list of servers (the
/// token and the relay key are kept by it, in the Keychain, like those of a scanned server) and nothing is kept here.
/// Without one (tests, previews) the device token goes to the secret store (one item per server) and a record of the
/// server to its own file, apart from `servers.v1`.
///
/// If the server cannot be added, `receive` throws and keeps nothing, so the grant stays in the account and the next cycle
/// tries once more. Nothing half-saved is left.
enum AccessSinkError: Error {
    /// The record names neither a relay nor a direct address this app can use.
    case noWayIn
}

actor AccountAccessSink: ServerAccessSink {
    static func tokenAccount(_ serverID: UUID) -> String { "access-token-\(serverID.uuidString.lowercased())" }

    private let secrets: SecretStore
    private let file: URL
    private let session: AccessSession?
    private let noiseKeys: ServerNoiseKeyStore?
    private var records: [ReceivedAccess]?

    init(
        secrets: SecretStore, file: URL = AccountAccessSink.defaultFile(), session: AccessSession? = nil,
        noiseKeys: ServerNoiseKeyStore? = nil
    ) {
        self.secrets = secrets
        self.file = file
        self.session = session
        self.noiseKeys = noiseKeys
    }

    static func defaultFile() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "Bandito/account-access.v1.json")
    }

    func hasAccess(serverID: UUID) async -> Bool {
        await hasAccess(serverID: serverID, phone: nil)
    }

    func hasAccess(serverID: UUID, phone: SyncedPhone?) async -> Bool {
        if let session { return await session.holds(serverID, phone) }
        guard loadRecords().contains(where: { $0.serverID == serverID }) else { return false }
        return ((try? secrets.load(account: Self.tokenAccount(serverID))) ?? nil) != nil
    }

    func receive(_ access: ServerAccess) async throws {
        if let session, let noiseKeys {
            // The key made for the request is the one the daemon pinned on the device row it issued.
            let key = try noiseKeys.privateKey(for: access.serverID)
            guard let config = access.serverConfig(noiseKey: key) else { throw AccessSinkError.noWayIn }
            try await session.add(config)
            return
        }
        let account = Self.tokenAccount(access.serverID)
        let previous = try secrets.load(account: account)
        try secrets.save(Data(access.deviceToken.utf8), account: account)
        var next = loadRecords().filter { $0.serverID != access.serverID }
        next.append(ReceivedAccess(serverID: access.serverID, name: access.name, phone: access.phone, receivedAt: Date()))
        do {
            try write(next)
        } catch {
            try? secrets.save(previous, account: account)
            throw error
        }
        records = next
    }

    /// Every access received so far.
    func all() -> [ReceivedAccess] { loadRecords() }

    /// The token for `serverID`, if this iPhone holds one.
    func token(for serverID: UUID) -> String? {
        guard let data = (try? secrets.load(account: Self.tokenAccount(serverID))) ?? nil else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Forgets one server's access (token and record).
    func remove(serverID: UUID) throws {
        try secrets.save(nil, account: Self.tokenAccount(serverID))
        let next = loadRecords().filter { $0.serverID != serverID }
        try write(next)
        records = next
    }

    private func loadRecords() -> [ReceivedAccess] {
        if let records { return records }
        guard let data = try? Data(contentsOf: file),
            let decoded = try? Self.decoder.decode([ReceivedAccess].self, from: data)
        else {
            return []
        }
        records = decoded
        return decoded
    }

    private func write(_ list: [ReceivedAccess]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(list).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
