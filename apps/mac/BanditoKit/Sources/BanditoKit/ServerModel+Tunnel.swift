import Foundation

// Reaching what runs on a server's localhost (docs/ARCHITECTURE.md#tunnel).

extension ServerModel {
    /// A local URL that reaches `127.0.0.1:<port>` on the server.
    ///
    /// - This Mac: `http://127.0.0.1:<port>` directly.
    /// - WebSocket server: a `PortForwarder` on a loopback port of this Mac, one per remote port, reused
    ///   by later calls and closed by `disconnect()`.
    public func forward(port: Int) async throws -> URL {
        guard (1...65_535).contains(port) else {
            throw RPCError(code: RPCError.invalidParams, message: "port must be 1…65535")
        }
        switch config.endpoint {
        case .local:
            // Force unwrap: the string is built from an Int and always a valid URL.
            return URL(string: "http://127.0.0.1:\(port)")!
        case .webSocket(let server):
            let forwarder: PortForwarder
            if let existing = forwarders[port] {
                forwarder = existing
            } else {
                guard let tunnel = Self.tunnelURL(for: server, port: port) else {
                    throw RPCError(code: RPCError.invalidParams, message: "the server address is not usable")
                }
                forwarder = try PortForwarder(tunnelURL: tunnel, token: config.token)
                forwarders[port] = forwarder
            }
            let local: UInt16
            do {
                local = try await forwarder.localPort()
            } catch {
                forwarders[port] = nil
                throw error
            }
            // Force unwrap: the string is built from a UInt16 and always a valid URL.
            return URL(string: "http://127.0.0.1:\(local)")!
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
        let all = Array(forwarders.values)
        forwarders.removeAll()
        for forwarder in all {
            await forwarder.stop()
        }
    }
}
