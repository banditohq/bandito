import Foundation

// Reaching what runs on a server's localhost (docs/ARCHITECTURE.md#tunnel).

extension ServerModel {
    /// A local URL that reaches `127.0.0.1:<port>` on the server, for one client inside this app
    /// (a VNC or DevTools client, for example). Each call makes a new one-shot forwarder.
    ///
    /// Why one-shot: a forwarder that stays open would give every local process on this Mac a
    /// loopback port that goes to the server with the device token. Here the port serves exactly one
    /// connection, the one the app makes right after this call returns.
    /// HTTP previews of sites will go through the daemon's HTTP proxy with `Authorization`, not through
    /// a local port.
    ///
    /// - This Mac: `http://127.0.0.1:<port>` directly, no forwarder.
    /// - WebSocket server: a `PortForwarder` on a loopback port of this Mac. It is closed by
    ///   `disconnect()`, or at once after its one connection.
    public func forwardOnce(port: Int) async throws -> URL {
        guard (1...65_535).contains(port) else {
            throw RPCError(code: RPCError.invalidParams, message: "port must be 1…65535")
        }
        switch config.endpoint {
        case .local:
            // Force unwrap: the string is built from an Int and always a valid URL.
            return URL(string: "http://127.0.0.1:\(port)")!
        case .webSocket(let server):
            guard let tunnel = Self.tunnelURL(for: server, port: port) else {
                throw RPCError(code: RPCError.invalidParams, message: "the server address is not usable")
            }
            let forwarder = try PortForwarder(tunnelURL: tunnel, token: config.token, oneShot: true)
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
    }

    /// The server's `/v1/tunnel?port=N` WebSocket, with the scheme and path of the server's URL replaced.
    static func tunnelURL(for server: URL, port: Int) -> URL? {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/v1/tunnel"
        components.percentEncodedQuery = "port=\(port)"
        components.fragment = nil
        return components.url
    }

    func stopForwarders() async {
        let all = forwarders
        forwarders.removeAll()
        for forwarder in all {
            await forwarder.stop()
        }
    }
}
