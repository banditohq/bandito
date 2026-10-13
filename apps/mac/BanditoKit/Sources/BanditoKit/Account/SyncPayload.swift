import Foundation

/// What the account syncs between devices, as one encrypted blob. Device tokens are never in it:
/// each device pairs with each server itself (or is issued a token by another device: `accessRequests`, `accessGrants`).
///
/// Forward compatibility: a field this build does not know is kept in `extras` and written back, so a device on an
/// older build does not erase what a newer one added. A blob written before `accessRequests` existed decodes with
/// the lists empty, and a payload with empty lists encodes without them.
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
    /// Devices that ask for access to a server (docs/RELAY.md, "One account on every device").
    public var accessRequests: [AccessRequest] = []
    /// Answers to those requests: the device token sealed to the asking device.
    public var accessGrants: [AccessGrant] = []
    /// Top-level fields of the blob that this build does not know.
    public var extras: [String: JSONValue] = [:]

    public init(
        version: Int = SyncPayload.currentVersion,
        servers: [SyncedServer] = [],
        keymap: Data? = nil,
        snippets: [JSONValue]? = nil,
        profile: SyncedProfile? = nil,
        accessRequests: [AccessRequest] = [],
        accessGrants: [AccessGrant] = [],
        extras: [String: JSONValue] = [:]
    ) {
        self.version = version
        self.servers = servers
        self.keymap = keymap
        self.snippets = snippets
        self.profile = profile
        self.accessRequests = accessRequests
        self.accessGrants = accessGrants
        self.extras = extras
    }

    private enum Keys: String, CaseIterable {
        case version, servers, keymap, snippets, profile
        case accessRequests = "access_requests"
        case accessGrants = "access_grants"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        version = try c.decode(Int.self, forKey: DynamicKey(Keys.version.rawValue))
        servers = try c.decodeIfPresent([SyncedServer].self, forKey: DynamicKey(Keys.servers.rawValue)) ?? []
        keymap = try c.decodeIfPresent(Data.self, forKey: DynamicKey(Keys.keymap.rawValue))
        snippets = try c.decodeIfPresent([JSONValue].self, forKey: DynamicKey(Keys.snippets.rawValue))
        profile = try c.decodeIfPresent(SyncedProfile.self, forKey: DynamicKey(Keys.profile.rawValue))
        accessRequests =
            try c.decodeIfPresent([AccessRequest].self, forKey: DynamicKey(Keys.accessRequests.rawValue)) ?? []
        accessGrants = try c.decodeIfPresent([AccessGrant].self, forKey: DynamicKey(Keys.accessGrants.rawValue)) ?? []
        extras = try DynamicKey.extras(in: c, known: Keys.allCases.map(\.rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try DynamicKey.encodeExtras(extras, into: &c, known: Keys.allCases.map(\.rawValue))
        try c.encode(version, forKey: DynamicKey(Keys.version.rawValue))
        try c.encode(servers, forKey: DynamicKey(Keys.servers.rawValue))
        try c.encodeIfPresent(keymap, forKey: DynamicKey(Keys.keymap.rawValue))
        try c.encodeIfPresent(snippets, forKey: DynamicKey(Keys.snippets.rawValue))
        try c.encodeIfPresent(profile, forKey: DynamicKey(Keys.profile.rawValue))
        if !accessRequests.isEmpty { try c.encode(accessRequests, forKey: DynamicKey(Keys.accessRequests.rawValue)) }
        if !accessGrants.isEmpty { try c.encode(accessGrants, forKey: DynamicKey(Keys.accessGrants.rawValue)) }
    }
}

/// A coding key made from any string, so a type can keep the fields it does not know (`extras`).
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    /// The fields of `container` whose names are not in `known`.
    static func extras(in container: KeyedDecodingContainer<DynamicKey>, known: [String]) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            result[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return result
    }

    /// Writes `extras` except names that `known` fields own: an unknown field can never shadow a known one.
    static func encodeExtras(
        _ extras: [String: JSONValue], into container: inout KeyedEncodingContainer<DynamicKey>, known: [String]
    ) throws {
        for (name, value) in extras.sorted(by: { $0.key < $1.key }) where !known.contains(name) {
            try container.encode(value, forKey: DynamicKey(name))
        }
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
    /// How any device reaches the daemon without ssh (relay, direct address). Written by the device that turns
    /// it on. Nil when the server has none, or when the writer is a build that does not know it.
    public var phone: SyncedPhone?
    /// Fields of this server that this build does not know.
    public var extras: [String: JSONValue]

    public init(
        id: UUID, name: String, endpoint: SyncedEndpoint, addedAt: Int64, phone: SyncedPhone? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.addedAt = addedAt
        self.phone = phone
        self.extras = extras
    }

    private static let known = ["id", "name", "endpoint", "addedAt", "phone"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        id = try c.decode(UUID.self, forKey: DynamicKey("id"))
        name = try c.decode(String.self, forKey: DynamicKey("name"))
        endpoint = try c.decode(SyncedEndpoint.self, forKey: DynamicKey("endpoint"))
        addedAt = try c.decode(Int64.self, forKey: DynamicKey("addedAt"))
        phone = try c.decodeIfPresent(SyncedPhone.self, forKey: DynamicKey("phone"))
        extras = try DynamicKey.extras(in: c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try DynamicKey.encodeExtras(extras, into: &c, known: Self.known)
        try c.encode(id, forKey: DynamicKey("id"))
        try c.encode(name, forKey: DynamicKey("name"))
        try c.encode(endpoint, forKey: DynamicKey("endpoint"))
        try c.encode(addedAt, forKey: DynamicKey("addedAt"))
        try c.encodeIfPresent(phone, forKey: DynamicKey("phone"))
    }
}

/// How a device reaches a server without ssh: through Bandito Relay (`sid`, `relayHost`, `nk`), directly (`fp`,
/// `hosts`), or both. Written by whichever device turns that access on. Never holds a secret: `nk` and `fp` are public
/// keys the phone pins.
public struct SyncedPhone: Codable, Sendable, Equatable {
    /// The server's relay id.
    public var sid: String?
    /// The relay's host (`relay.bandito.dev`).
    public var relayHost: String?
    /// The daemon's Noise static public key (base64url, 32 bytes).
    public var nk: String?
    /// SHA-256 of the daemon's phone certificate (64 lower-case hex digits).
    public var fp: String?
    /// `host:port` addresses of the phone listener, best first.
    public var hosts: [String]
    public var extras: [String: JSONValue]

    public init(
        sid: String? = nil, relayHost: String? = nil, nk: String? = nil, fp: String? = nil, hosts: [String] = [],
        extras: [String: JSONValue] = [:]
    ) {
        self.sid = sid
        self.relayHost = relayHost
        self.nk = nk
        self.fp = fp
        self.hosts = hosts
        self.extras = extras
    }

    /// There is a way in: relay (id, host and key) or a direct address with its fingerprint.
    public var isReachable: Bool {
        (sid != nil && relayHost != nil && nk != nil) || (fp != nil && !hosts.isEmpty)
    }

    private static let known = ["sid", "relay_host", "nk", "fp", "hosts"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        sid = try c.decodeIfPresent(String.self, forKey: DynamicKey("sid"))
        relayHost = try c.decodeIfPresent(String.self, forKey: DynamicKey("relay_host"))
        nk = try c.decodeIfPresent(String.self, forKey: DynamicKey("nk"))
        fp = try c.decodeIfPresent(String.self, forKey: DynamicKey("fp"))
        hosts = try c.decodeIfPresent([String].self, forKey: DynamicKey("hosts")) ?? []
        extras = try DynamicKey.extras(in: c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try DynamicKey.encodeExtras(extras, into: &c, known: Self.known)
        try c.encodeIfPresent(sid, forKey: DynamicKey("sid"))
        try c.encodeIfPresent(relayHost, forKey: DynamicKey("relay_host"))
        try c.encodeIfPresent(nk, forKey: DynamicKey("nk"))
        try c.encodeIfPresent(fp, forKey: DynamicKey("fp"))
        try c.encode(hosts, forKey: DynamicKey("hosts"))
    }
}

/// A device of the account asks for a token of a server (docs/RELAY.md, "One account on every device").
public struct AccessRequest: Codable, Sendable, Equatable {
    /// The asking device, as the account knows it (`AccountDevice.id`).
    public var deviceID: String
    /// `SyncedServer.id`, lower or upper case as written by the asking device.
    public var serverID: String
    /// The Noise static public key (base64url) the asking device made for this server. The daemon row is made with it.
    public var noiseKey: String
    /// The asking device's X25519 public key (base64). The answer is sealed to it. Inside the encrypted blob, so the
    /// account server cannot swap it. Absent in requests of builds that rely on `GET /me`.
    public var publicKey: String?
    /// Unix milliseconds.
    public var at: Int64
    public var extras: [String: JSONValue]

    public init(
        deviceID: String, serverID: String, noiseKey: String, publicKey: String? = nil, at: Int64,
        extras: [String: JSONValue] = [:]
    ) {
        self.deviceID = deviceID
        self.serverID = AccessKey.normalized(serverID)
        self.noiseKey = noiseKey
        self.publicKey = publicKey
        self.at = at
        self.extras = extras
    }

    private static let known = ["device_id", "server_id", "noise_key", "public_key", "at"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        deviceID = try c.decode(String.self, forKey: DynamicKey("device_id"))
        serverID = AccessKey.normalized(try c.decode(String.self, forKey: DynamicKey("server_id")))
        noiseKey = try c.decode(String.self, forKey: DynamicKey("noise_key"))
        publicKey = try c.decodeIfPresent(String.self, forKey: DynamicKey("public_key"))
        at = try c.decode(Int64.self, forKey: DynamicKey("at"))
        extras = try DynamicKey.extras(in: c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try DynamicKey.encodeExtras(extras, into: &c, known: Self.known)
        try c.encode(deviceID, forKey: DynamicKey("device_id"))
        try c.encode(serverID, forKey: DynamicKey("server_id"))
        try c.encode(noiseKey, forKey: DynamicKey("noise_key"))
        try c.encodeIfPresent(publicKey, forKey: DynamicKey("public_key"))
        try c.encode(at, forKey: DynamicKey("at"))
    }

    var key: AccessKey { AccessKey(deviceID: deviceID, serverID: serverID) }
}

/// The answer to an `AccessRequest`: the daemon's device token, sealed to the asking device (`DeviceTokenSeal`).
public struct AccessGrant: Codable, Sendable, Equatable {
    public var deviceID: String
    public var serverID: String
    /// Base64 of the HPKE message.
    public var sealed: String
    /// Unix milliseconds.
    public var at: Int64
    public var extras: [String: JSONValue]

    public init(deviceID: String, serverID: String, sealed: String, at: Int64, extras: [String: JSONValue] = [:]) {
        self.deviceID = deviceID
        self.serverID = AccessKey.normalized(serverID)
        self.sealed = sealed
        self.at = at
        self.extras = extras
    }

    private static let known = ["device_id", "server_id", "sealed", "at"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        deviceID = try c.decode(String.self, forKey: DynamicKey("device_id"))
        serverID = AccessKey.normalized(try c.decode(String.self, forKey: DynamicKey("server_id")))
        sealed = try c.decode(String.self, forKey: DynamicKey("sealed"))
        at = try c.decode(Int64.self, forKey: DynamicKey("at"))
        extras = try DynamicKey.extras(in: c, known: Self.known)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try DynamicKey.encodeExtras(extras, into: &c, known: Self.known)
        try c.encode(deviceID, forKey: DynamicKey("device_id"))
        try c.encode(serverID, forKey: DynamicKey("server_id"))
        try c.encode(sealed, forKey: DynamicKey("sealed"))
        try c.encode(at, forKey: DynamicKey("at"))
    }

    var key: AccessKey { AccessKey(deviceID: deviceID, serverID: serverID) }
}

/// The identity of a request or a grant: one per device and server.
struct AccessKey: Hashable {
    var deviceID: String
    var serverID: String

    /// Server ids are UUIDs; they compare in lower case, so `A…` and `a…` are one server.
    static func normalized(_ serverID: String) -> String { serverID.lowercased() }
}

extension SyncPayload {
    /// How long a request or a grant lives: a week. Older ones are dropped by `pruned`.
    public static let accessLifetimeMs: Int64 = 7 * 24 * 3600 * 1000

    /// The payload without requests and grants older than a week. Entries dated in the future are kept (a clock
    /// that is a little ahead must not lose them), but not for longer than a week past `now`.
    public func pruned(now: Date) -> SyncPayload {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var copy = self
        copy.accessRequests = accessRequests.filter { nowMs - $0.at <= Self.accessLifetimeMs && $0.at - nowMs <= Self.accessLifetimeMs }
        copy.accessGrants = accessGrants.filter { nowMs - $0.at <= Self.accessLifetimeMs && $0.at - nowMs <= Self.accessLifetimeMs }
        return copy
    }

    /// Joins two copies of the payload (the rule of every merge in the app).
    ///
    /// - Servers are matched by `id`: the local copy wins for an id both have, and ids only one side has are kept.
    ///   Inside a server, a `phone` the local copy lacks is taken from the remote one, and unknown fields of both
    ///   are kept (the local value wins on a name both have).
    /// - Keymap and snippets: local when there is one. Profile: the newer `updatedAt`, a tie keeps local.
    /// - Requests and grants: one per device and server, the later `at` wins (a tie keeps local). There are no
    ///   tombstones, so code that removes an answered request does it on a fresh copy (`SyncStore.update`), and the
    ///   reader treats a request that already has a grant, or that this device holds a token for, as done.
    /// - Unknown top-level fields of both sides are kept; local wins on a name both have.
    /// - Entries older than a week are dropped (`pruned`).
    public static func merged(local: SyncPayload, remote: SyncPayload, now: Date = Date()) -> SyncPayload {
        var servers = remote.servers
        for server in local.servers {
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index] = server.merged(over: servers[index])
            } else {
                servers.append(server)
            }
        }
        var merged = SyncPayload(
            version: SyncPayload.currentVersion,
            servers: servers,
            keymap: local.keymap ?? remote.keymap,
            snippets: local.snippets ?? remote.snippets,
            profile: SyncedProfile.newer(local.profile, remote.profile),
            accessRequests: newest(local.accessRequests, remote.accessRequests, key: \.key, at: \.at),
            accessGrants: newest(local.accessGrants, remote.accessGrants, key: \.key, at: \.at),
            extras: remote.extras.merging(local.extras) { _, mine in mine })
        merged = merged.pruned(now: now)
        return merged
    }

    private static func newest<T>(
        _ local: [T], _ remote: [T], key: KeyPath<T, AccessKey>, at: KeyPath<T, Int64>
    ) -> [T] {
        var result = remote
        for item in local {
            if let index = result.firstIndex(where: { $0[keyPath: key] == item[keyPath: key] }) {
                if item[keyPath: at] >= result[index][keyPath: at] { result[index] = item }
            } else {
                result.append(item)
            }
        }
        // Remote entries that the local copy replaced keep the position; a duplicate on one side collapses too.
        var seen = Set<AccessKey>()
        var unique: [T] = []
        for item in result.reversed() where seen.insert(item[keyPath: key]).inserted { unique.append(item) }
        return unique.reversed()
    }
}

extension SyncedServer {
    /// This copy (the winner) over `other`: the `phone` and unknown fields it lacks come from `other`.
    func merged(over other: SyncedServer) -> SyncedServer {
        var result = self
        if result.phone == nil { result.phone = other.phone }
        result.extras = other.extras.merging(extras) { _, mine in mine }
        return result
    }
}

/// How the other device reaches the server. Each device adds its own token after it pairs.
public enum SyncedEndpoint: Codable, Sendable, Equatable {
    /// Over ssh: the target as the user typed it, without the remote port.
    case ssh(host: String, user: String?, port: Int?)
    /// A WebSocket URL (a tailnet address, `wss://…`).
    case webSocket(url: URL)
    /// The daemon on the Mac with this device ID.
    case local(deviceID: String)
}
