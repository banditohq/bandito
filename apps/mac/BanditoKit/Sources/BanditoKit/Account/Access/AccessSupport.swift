import CryptoKit
import Foundation

/// What a device receives when another device of the account answers its request: the daemon, how to reach it, and the
/// device token that daemon issued for this device. The token is a secret: it is not printed.
public struct ServerAccess: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let serverID: UUID
    public let name: String
    public let phone: SyncedPhone
    public let deviceToken: String

    public init(serverID: UUID, name: String, phone: SyncedPhone, deviceToken: String) {
        self.serverID = serverID
        self.name = name
        self.phone = phone
        self.deviceToken = deviceToken
    }

    public var description: String { "ServerAccess(\(serverID), token: <redacted>)" }
    public var debugDescription: String { description }
}

/// Where a new access ends up. The requesting side (`AccessRequester`) gives it every token it opens. The app
/// implements it: it keeps the token in the Keychain, adds the server to its list and connects (relay or direct).
public protocol ServerAccessSink: Sendable {
    /// Whether this device already holds a token for the server `serverID` (the id the account syncs).
    func hasAccess(serverID: UUID) async -> Bool
    /// The same, for a server the account knows with this `phone` record: also true when this device holds the same
    /// daemon under another id (it was paired by link here before the account knew it). The default asks by id only.
    func hasAccess(serverID: UUID, phone: SyncedPhone?) async -> Bool
    /// Takes the new access. Throwing keeps the grant in the blob, and the next cycle tries again, so an
    /// implementation that failed must not have kept half of it.
    func receive(_ access: ServerAccess) async throws
}

extension ServerAccessSink {
    public func hasAccess(serverID: UUID, phone: SyncedPhone?) async -> Bool { await hasAccess(serverID: serverID) }
}

/// The Noise static key this device uses for one server (docs/RELAY.md): made on the first request for the server,
/// kept in the secret store, and never leaves the device. Its public half goes in the request, and the daemon pins it on
/// the device row it issues; the relay transport proves it with the private half.
public struct ServerNoiseKeyStore: Sendable {
    private let secrets: SecretStore

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    static func account(for serverID: UUID) -> String {
        "noise-\(serverID.uuidString.lowercased())"
    }

    /// The private key (32 bytes) for `serverID`, made when there is none.
    public func privateKey(for serverID: UUID) throws -> Data {
        if let raw = try secrets.load(account: Self.account(for: serverID)), raw.count == 32 { return raw }
        let raw = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        try secrets.save(raw, account: Self.account(for: serverID))
        return raw
    }

    /// The private key if one was made, without making one.
    public func existingPrivateKey(for serverID: UUID) throws -> Data? {
        guard let raw = try secrets.load(account: Self.account(for: serverID)), raw.count == 32 else { return nil }
        return raw
    }

    /// The public key as the daemon wants it: base64url without padding.
    public func publicKey(for serverID: UUID) throws -> String {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try privateKey(for: serverID))
        return Self.base64URL(key.publicKey.rawRepresentation)
    }

    public func remove(_ serverID: UUID) throws {
        try secrets.save(nil, account: Self.account(for: serverID))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A daemon this device can talk to now, seen by the account code: it issues device tokens, says how a phone reaches
/// it, and revokes device rows. `ServerModel` is one.
@MainActor
public protocol AccessServer: AnyObject {
    /// `SyncedServer.id`: the id this server has in the account.
    var accessServerID: UUID { get }
    /// Connected right now. A server that is not connected is skipped by this cycle.
    var isReachable: Bool { get }
    func issueDeviceToken(name: String, platform: String, noiseKey: String?) async throws -> IssuedDevice
    func phoneInfo() async throws -> PhoneInfo?
    func deviceRows() async throws -> [Device]
    func revokeDeviceRow(_ id: String) async throws
}

/// `devices.issue`: a new device row and its token.
public struct IssuedDevice: Decodable, Sendable, Equatable {
    /// The daemon's id of the new row (`devices.revoke` takes it).
    public var deviceId: String
    public var token: String

    public init(deviceId: String, token: String) {
        self.deviceId = deviceId
        self.token = token
    }
}

/// `phone.info`: how a phone reaches the daemon. Relay fields are nil while relay mode is off, `hosts` is empty while
/// no phone listener is up.
public struct PhoneInfo: Decodable, Sendable, Equatable {
    public var relay: String?
    public var relayHost: String?
    public var sid: String?
    public var noiseKey: String?
    public var fingerprint: String?
    public var hosts: [String]

    public init(
        relay: String? = nil, relayHost: String? = nil, sid: String? = nil, noiseKey: String? = nil,
        fingerprint: String? = nil, hosts: [String] = []
    ) {
        self.relay = relay
        self.relayHost = relayHost
        self.sid = sid
        self.noiseKey = noiseKey
        self.fingerprint = fingerprint
        self.hosts = hosts
    }

    /// The record for the account blob, or nil when there is no way in: neither relay nor a direct address.
    public var synced: SyncedPhone? {
        let viaRelay = sid != nil && relayHost != nil && noiseKey != nil
        let direct = fingerprint != nil && !hosts.isEmpty
        guard viaRelay || direct else { return nil }
        return SyncedPhone(
            sid: viaRelay ? sid : nil, relayHost: viaRelay ? relayHost : nil, nk: viaRelay ? noiseKey : nil,
            fp: direct ? fingerprint : nil, hosts: direct ? hosts : [])
    }
}

extension ServerModel: AccessServer {
    public var accessServerID: UUID { config.id }
    public var isReachable: Bool { state == .connected }

    public func issueDeviceToken(name: String, platform: String, noiseKey: String?) async throws -> IssuedDevice {
        struct P: Encodable {
            var name: String
            var platform: String
            var noiseKey: String?
        }
        return try await rpc().call(
            "devices.issue", P(name: name, platform: platform, noiseKey: noiseKey), as: IssuedDevice.self)
    }

    /// Nil on a daemon that does not know `phone.info` (an older one).
    public func phoneInfo() async throws -> PhoneInfo? {
        do {
            return try await rpc().call("phone.info", NoParams(), as: PhoneInfo.self)
        } catch let error as RPCError where error.code == RPCError.methodNotFound {
            return nil
        }
    }

    public func deviceRows() async throws -> [Device] {
        try await devices()
    }

    public func revokeDeviceRow(_ id: String) async throws {
        try await revokeDevice(id)
    }
}

/// The phone records of the servers this device is connected to, for the account blob.
public enum PhoneRecords {
    /// Asks every reachable server how a phone reaches it. A server that does not answer, or has no way in, is left out
    /// (its earlier record stays in the blob: see `SyncPayload.merged`).
    @MainActor
    public static func collect(from servers: [any AccessServer]) async -> [UUID: SyncedPhone] {
        var records: [UUID: SyncedPhone] = [:]
        for server in servers where server.isReachable {
            if let phone = (try? await server.phoneInfo())?.synced { records[server.accessServerID] = phone }
        }
        return records
    }
}
