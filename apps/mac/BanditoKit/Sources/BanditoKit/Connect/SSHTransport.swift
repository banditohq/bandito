import Foundation

#if os(macOS)

/// The RPC channel to a server over ssh: opens an `SSHTunnel`, then the WebSocket on the tunnel's local port.
/// Closing the transport closes both. Single use, like `WebSocketTransport`.
public actor SSHTransport: RPCTransport {
    private let target: String
    private let remotePort: Int
    private let token: String?
    private let sshPath: String
    private var tunnel: SSHTunnel?
    private var socket: WebSocketTransport?

    public init(target: String, remotePort: Int, token: String?, sshPath: String = SSHTunnel.sshPath) {
        self.target = target
        self.remotePort = remotePort
        self.token = token
        self.sshPath = sshPath
    }

    public func connect() async throws {
        let tunnel = try SSHTunnel(target: target, remotePort: remotePort, sshPath: sshPath)
        self.tunnel = tunnel
        try await tunnel.start()
        guard let url = await tunnel.localURL else {
            throw RPCError(code: RPCError.disconnected, message: "the ssh tunnel has no local port")
        }
        // The token travels only to loopback: the tunnel's local end, so `WebSocketTransport` allows it.
        let socket = WebSocketTransport(url: url, token: token)
        self.socket = socket
        try await socket.connect()
    }

    public func send(_ text: String) async throws {
        guard let socket else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        try await socket.send(text)
    }

    public func receive() async throws -> String {
        guard let socket else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        return try await socket.receive()
    }

    public func close() async {
        await socket?.close()
        socket = nil
        await tunnel?.stop()
        tunnel = nil
    }

    /// The tunnel's HTTP base, as long as the tunnel is up (see `SSHTunnel.httpBase`).
    public var httpBase: URL? {
        get async { await tunnel?.httpBase }
    }
}

#endif

/// A transport for a kind of server this platform cannot reach yet. Connecting fails with `reason`.
public struct UnavailableTransport: RPCTransport {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func connect() async throws {
        throw RPCError(code: RPCError.disconnected, message: reason)
    }

    public func send(_ text: String) async throws {
        throw RPCError(code: RPCError.disconnected, message: reason)
    }

    public func receive() async throws -> String {
        throw RPCError(code: RPCError.disconnected, message: reason)
    }

    public func close() async {}
}
