import CryptoKit
import Foundation

/// A server that can be reached more than one way: its direct addresses (TLS, pinned certificate) first, then Bandito
/// Relay (Noise, pinned key). Single use, like the transports it wraps. Which way worked is `connectedRoute`.
public actor ReachableTransport: RPCTransport, RouteReporting {
    /// How long the direct addresses get when the relay is the way out: a phone away from home must not wait long for
    /// an address of a home network.
    public static let directTimeoutWithRelay: Duration = .seconds(3)

    private let hosts: [String]
    private let fingerprint: String?
    private let relay: RelayRoute?
    private let daemonKey: Data?
    private let phoneKey: Curve25519.KeyAgreement.PrivateKey?
    private let token: String?
    private let directTimeout: Duration
    private let relayTimeout: Duration
    private let memory: DirectHostMemory
    private var inner: RPCTransport?
    public private(set) var connectedRoute: ConnectionRoute?

    /// - Parameters:
    ///   - token: the device token; nil for a first pairing (`pair.redeem`).
    public init(
        hosts: [String], fingerprint: String?, relay: RelayRoute?, daemonKey: Data?,
        phoneKey: Curve25519.KeyAgreement.PrivateKey?, token: String?, directTimeout: Duration? = nil,
        relayTimeout: Duration = RelayTransport.defaultTimeout, memory: DirectHostMemory = .shared
    ) {
        self.hosts = hosts
        self.fingerprint = fingerprint.flatMap { PinnedFingerprint.normalize($0) }
        self.relay = relay
        self.daemonKey = daemonKey
        self.phoneKey = phoneKey
        self.token = token
        self.directTimeout =
            directTimeout ?? (relay == nil ? DirectTransport.defaultHostTimeout : Self.directTimeoutWithRelay)
        self.relayTimeout = relayTimeout
        self.memory = memory
    }

    /// The way a saved server is reached. A server whose phone key is lost cannot use the relay.
    public init(config: ServerConfig, directTimeout: Duration? = nil) {
        let direct = config.endpoint.directPart
        let route = config.endpoint.relayPart
        self.init(
            hosts: direct?.hosts ?? [], fingerprint: direct?.fingerprint, relay: route?.route, daemonKey: route?.noiseKey,
            phoneKey: config.noisePrivateKey, token: config.token, directTimeout: directTimeout)
    }

    public func connect() async throws {
        var directError: Error?
        if !hosts.isEmpty, let fingerprint {
            let direct = DirectTransport(hosts: hosts, fingerprint: fingerprint, token: token, hostTimeout: directTimeout, memory: memory)
            do {
                try await direct.connect()
                inner = direct
                connectedRoute = .network
                return
            } catch {
                await direct.close()
                // The server is there and refuses this device: the relay would meet the same server.
                if let rpc = error as? RPCError, rpc.code == RPCError.keyRejected || rpc.code == RPCError.rateLimited { throw rpc }
                directError = error
            }
        }
        try Task.checkCancellation()
        guard let relay, let daemonKey, let phoneKey else {
            throw directError ?? RPCError(code: RPCError.disconnected, message: "the server has no usable address")
        }
        let cloud = RelayTransport(
            route: relay, daemonKey: daemonKey, phoneKey: phoneKey, role: token.map { .device(token: $0) } ?? .pairing,
            timeout: relayTimeout)
        do {
            try await cloud.connect()
            inner = cloud
            connectedRoute = .cloud
        } catch {
            await cloud.close()
            // Someone else answers at the pinned address: that is worth more than "the relay is busy".
            if let rpc = directError as? RPCError, rpc.code == RPCError.fingerprintMismatch.code,
                !(error is CancellationError)
            {
                throw rpc
            }
            throw error
        }
    }

    public func send(_ text: String) async throws {
        guard let inner else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        try await inner.send(text)
    }

    public func receive() async throws -> String {
        guard let inner else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        return try await inner.receive()
    }

    public func close() async {
        await inner?.close()
        inner = nil
        connectedRoute = nil
    }
}

extension DirectTransport: RouteReporting {
    public var connectedRoute: ConnectionRoute? { connectedHost == nil ? nil : .network }
}
