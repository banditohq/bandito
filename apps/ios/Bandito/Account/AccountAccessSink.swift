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

/// Keeps what the account hands this iPhone: the device token in the secret store (the Keychain; one item per server)
/// and a record of the server in its own file, apart from the paired servers of `ServerSession` (`servers.v1`).
///
/// The token is saved first; if the record cannot be written the token is removed again and `receive` throws, so the grant
/// stays in the account and the next cycle tries once more. Nothing half-saved is left.
actor AccountAccessSink: ServerAccessSink {
    static func tokenAccount(_ serverID: UUID) -> String { "access-token-\(serverID.uuidString.lowercased())" }

    private let secrets: SecretStore
    private let file: URL
    private var records: [ReceivedAccess]?

    init(secrets: SecretStore, file: URL = AccountAccessSink.defaultFile()) {
        self.secrets = secrets
        self.file = file
    }

    static func defaultFile() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "Bandito/account-access.v1.json")
    }

    func hasAccess(serverID: UUID) async -> Bool {
        guard loadRecords().contains(where: { $0.serverID == serverID }) else { return false }
        return ((try? secrets.load(account: Self.tokenAccount(serverID))) ?? nil) != nil
    }

    func receive(_ access: ServerAccess) async throws {
        // TODO(coordinator): hand `access` to the connection layer. Build the server for it from `access.phone` (relay:
        // sid, relayHost, nk; direct: hosts, fp) with the Noise key of `ServerNoiseKeyStore.privateKey(for: access.serverID)`
        // and `access.deviceToken`, add it to `ServerSession` and connect, so the server appears in the Crew. Until then
        // the token and the record are only stored, and the account screen shows the server as connected.
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
