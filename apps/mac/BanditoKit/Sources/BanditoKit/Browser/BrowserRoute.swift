import Foundation

// The daemon's browser routes (`/v1/browser/tabs`, `/v1/browser/cdp…`, docs/ARCHITECTURE.md#browser).
// They take the device token as `Authorization: Bearer` and no `Origin`, like the file routes.

/// The address of a browser route, built from the server's own address.
public enum BrowserRoute {
    /// `path` on the same server as `server`, with the scheme the request needs: `http`/`https` for a plain
    /// request, `ws`/`wss` for a socket. `wss` and `https` count as secure; the others do not. The query
    /// carries `workspace` only when it is given. The token never goes into the URL.
    static func url(server: URL, path: String, workspace: String?, socket: Bool) -> URL? {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        let secure = ["wss", "https"].contains(components.scheme?.lowercased() ?? "")
        components.scheme = socket ? (secure ? "wss" : "ws") : (secure ? "https" : "http")
        components.path = path
        components.percentEncodedQuery = workspace.map { "workspace=" + ServerModel.queryEncoded($0) }
        components.fragment = nil
        return components.url
    }

    /// A target id as the daemon accepts it in a route: 1 to 64 ASCII letters or digits.
    static func isValidTargetID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

extension ServerModel {
    /// The request for a browser route (`path`, e.g. `/v1/browser/tabs`) on this server.
    ///
    /// - WebSocket server: the server's own origin, with `ws`/`wss` for sockets and `http`/`https` for plain
    ///   requests, and `Authorization: Bearer` when the server has a token. A token needs TLS or loopback
    ///   (`WebSocketTransport.allowsToken`); otherwise this throws instead of sending it in the clear.
    /// - SSH server: throws. The ssh tunnel's local port belongs to the transport, and the model does not own
    ///   one yet (see `BrowserRoute.url` for the address a tunnel gives).
    /// - This Mac: throws. The daemon's unix socket has no device token, and the routes need one.
    public func browserRequest(path: String, workspace: String?, socket: Bool) throws -> URLRequest {
        switch config.endpoint {
        case .local:
            throw RPCError(
                code: RPCError.unsupportedTransport,
                message: "the browser needs a paired device; add this Mac as a WebSocket server")
        case .ssh:
            throw RPCError(
                code: RPCError.unsupportedTransport, message: "the browser is not available over SSH yet")
        case .webSocket(let server):
            if config.token != nil, !WebSocketTransport.allowsToken(for: server) {
                throw RPCError(
                    code: RPCError.insecureTransport,
                    message: "refusing to send the device token over an unencrypted connection")
            }
            guard let url = BrowserRoute.url(server: server, path: path, workspace: workspace, socket: socket) else {
                throw RPCError(code: RPCError.invalidParams, message: "the server address is not usable")
            }
            var request = URLRequest(url: url)
            if let token = config.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return request
        }
    }
}
