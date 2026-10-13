import Foundation

/// What `POST /relay/servers` returns. The `secret` is shown once: it is held in memory only until the daemon has it.
public struct RelayRegistration: Decodable, Sendable, Equatable, CustomStringConvertible {
    public var sid: String
    public var secret: String
    public var relayURL: String

    public init(sid: String, secret: String, relayURL: String) {
        self.sid = sid
        self.secret = secret
        self.relayURL = relayURL
    }

    private enum CodingKeys: String, CodingKey {
        case sid, secret
        case relayURL = "relay_url"
    }

    /// Never prints the secret.
    public var description: String { "RelayRegistration(sid: \(sid))" }
}

/// One row of `GET /relay/servers`.
public struct RelayServerEntry: Decodable, Sendable, Equatable {
    public var sid: String
    public var name: String
    public var online: Bool
    public var createdAt: String?
    public var lastSeenAt: String?

    private enum CodingKeys: String, CodingKey {
        case sid, name, online
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

/// What the Mac needs from the account to turn the cloud on and off. `AccountClient` conforms.
public protocol RelayRegistrar: Sendable {
    func registerRelayServer(name: String) async throws -> RelayRegistration
    func relayServers() async throws -> [RelayServerEntry]
    func deleteRelayServer(sid: String) async throws
}

extension AccountClient: RelayRegistrar {}
