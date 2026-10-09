import Foundation

/// What the account syncs between devices, as one encrypted blob. Device tokens are never in it:
/// each device pairs with each server itself.
public struct SyncPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int = SyncPayload.currentVersion
    public var servers: [SyncedServer] = []
    /// Keyboard map, as the app exports it. Opaque here.
    public var keymap: Data? = nil
    /// Saved snippets. The shape is not fixed yet, so it is kept as JSON.
    public var snippets: [JSONValue]? = nil

    public init(
        version: Int = SyncPayload.currentVersion,
        servers: [SyncedServer] = [],
        keymap: Data? = nil,
        snippets: [JSONValue]? = nil
    ) {
        self.version = version
        self.servers = servers
        self.keymap = keymap
        self.snippets = snippets
    }
}

/// A server as the account knows it. Credentials are not part of it.
public struct SyncedServer: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var endpoint: SyncedEndpoint
    /// Unix milliseconds, as everywhere in Bandito.
    public var addedAt: Int64

    public init(id: UUID, name: String, endpoint: SyncedEndpoint, addedAt: Int64) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.addedAt = addedAt
    }
}

/// How another device reaches the server. Each device adds its own token after it pairs.
public enum SyncedEndpoint: Codable, Sendable, Equatable {
    /// Over ssh: the target as the user typed it, without the remote port.
    case ssh(host: String, user: String?, port: Int?)
    /// A WebSocket URL (a tailnet address, `wss://…`).
    case webSocket(url: URL)
    /// The daemon on the Mac with this device ID.
    case local(deviceID: String)
}
