import Foundation

// Bandito Relay on a server (docs/RELAY.md): the Mac registers the server at bandito.dev, hands the registration to the
// daemon (`relay.enable`), and the daemon keeps the outbound connection. Owner methods only; needs the `relay` feature.

/// `relay.status`.
public struct RelayStatus: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var connected: Bool
    public var sid: String?
    public var relayUrl: String?
    /// A short English sentence from the daemon about the last failure, nil when all is well.
    public var lastError: String?

    public init(enabled: Bool, connected: Bool, sid: String? = nil, relayUrl: String? = nil, lastError: String? = nil) {
        self.enabled = enabled
        self.connected = connected
        self.sid = sid
        self.relayUrl = relayUrl
        self.lastError = lastError
    }

    public static let off = RelayStatus(enabled: false, connected: false)
}

extension ServerModel {
    /// Whether this daemon can talk through the relay.
    public var supportsRelay: Bool { supports("relay") }

    public func relayStatus() async throws -> RelayStatus {
        try await rpc().call("relay.status", NoParams(), as: RelayStatus.self)
    }

    @discardableResult
    public func relayEnable(url: String, sid: String, secret: String) async throws -> RelayStatus {
        struct Params: Encodable {
            var relayUrl: String
            var sid: String
            var secret: String
        }
        return try await rpc().call(
            "relay.enable", Params(relayUrl: url, sid: sid, secret: secret), as: RelayStatus.self, timeout: .seconds(20))
    }

    @discardableResult
    public func relayDisable() async throws -> RelayStatus {
        try await rpc().call("relay.disable", NoParams(), as: RelayStatus.self, timeout: .seconds(20))
    }
}
