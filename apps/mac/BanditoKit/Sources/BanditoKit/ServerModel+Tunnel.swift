import Foundation

// Reaching what runs on a server's localhost (docs/ARCHITECTURE.md#tunnel).

extension ServerModel {
    /// A local URL that reaches `127.0.0.1:<port>` on the server, for one client inside this app
    /// (a VNC client, for example). Each call makes a new one-shot forwarder.
    ///
    /// Why one-shot: a forwarder that stays open would give every local process on this Mac a
    /// loopback port that goes to the server with the device token. Here the port serves exactly one
    /// connection, the one the app makes right after this call returns.
    ///
    /// - This Mac: `http://127.0.0.1:<port>` directly, no forwarder.
    /// - Any daemon server (WebSocket, or ssh through its tunnel): a `PortForwarder` on a loopback port of this
    ///   Mac, carried by the daemon's `/v1/tunnel` (see `forwardRequest`). It is closed by `disconnect()`, or at
    ///   once after its one connection.
    public func forwardOnce(port: Int) async throws -> URL {
        guard (1...65_535).contains(port) else {
            throw RPCError(code: RPCError.invalidParams, message: "port must be 1…65535")
        }
        if case .local = config.endpoint {
            // Force unwrap: the string is built from an Int and always a valid URL.
            return URL(string: "http://127.0.0.1:\(port)")!
        }
        let request = try await forwardRequest(port: port)
        let forwarder = PortForwarder(request: request, oneShot: true)
        forwarders.append(forwarder)
        do {
            let local = try await forwarder.localPort()
            // Force unwrap: the string is built from a UInt16 and always a valid URL.
            return URL(string: "http://127.0.0.1:\(local)")!
        } catch {
            await forwarder.stop()
            forwarders.removeAll { $0 === forwarder }
            throw error
        }
    }

    /// The upgrade request for `GET /v1/tunnel?port=<port>`: a WebSocket that carries one TCP connection to the
    /// daemon host's `127.0.0.1:<port>`. Same address and token rule as every daemon route.
    func forwardRequest(port: Int) async throws -> URLRequest {
        try await daemonRequest(path: "/v1/tunnel", query: [(name: "port", value: String(port))], socket: true)
    }

    func stopForwarders() async {
        let all = forwarders
        forwarders.removeAll()
        for forwarder in all {
            await forwarder.stop()
        }
    }
}
