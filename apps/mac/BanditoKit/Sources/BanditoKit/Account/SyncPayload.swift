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
    /// The owner's profile picture. Optional: a payload written before it existed has none.
    public var profile: SyncedProfile? = nil

    public init(
        version: Int = SyncPayload.currentVersion,
        servers: [SyncedServer] = [],
        keymap: Data? = nil,
        snippets: [JSONValue]? = nil,
        profile: SyncedProfile? = nil
    ) {
        self.version = version
        self.servers = servers
        self.keymap = keymap
        self.snippets = snippets
        self.profile = profile
    }
}

/// The owner's profile picture, so every Mac shows the same one. The copy with the newer `updatedAt` wins a merge.
/// Removing the picture is an explicit copy with `cleared` set: a payload without a profile at all (written by a build
/// that does not know it) says nothing, so it never removes a picture.
public struct SyncedProfile: Equatable, Sendable {
    /// A JPEG of 256 × 256 pixels, at most 64 KB. Nil when there is no picture (cleared, or never set).
    public var avatar: Data?
    /// The owner removed the picture at `updatedAt`.
    public var cleared: Bool
    /// Unix milliseconds of the last change of the picture.
    public var updatedAt: Int64

    public init(avatar: Data?, cleared: Bool = false, updatedAt: Int64) {
        self.avatar = avatar
        self.cleared = cleared
        self.updatedAt = updatedAt
    }
}

extension SyncedProfile {
    /// The profile with the later `updatedAt`. Nil only when neither side has one; a tie keeps `local`. A missing
    /// profile on one side is not a removal: the other side's copy stands, cleared or not.
    public static func newer(_ local: SyncedProfile?, _ remote: SyncedProfile?) -> SyncedProfile? {
        guard let remote else { return local }
        guard let local else { return remote }
        return remote.updatedAt > local.updatedAt ? remote : local
    }
}

extension SyncedProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case avatar, cleared, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        avatar = try container.decodeIfPresent(Data.self, forKey: .avatar)
        cleared = try container.decodeIfPresent(Bool.self, forKey: .cleared) ?? false
        updatedAt = try container.decode(Int64.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(avatar, forKey: .avatar)
        if cleared { try container.encode(true, forKey: .cleared) }
        try container.encode(updatedAt, forKey: .updatedAt)
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
