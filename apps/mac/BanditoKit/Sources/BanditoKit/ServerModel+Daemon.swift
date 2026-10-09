import Foundation

// The daemon's HTTP routes (`/v1/files/raw`, `/v1/browser/…`) for every kind of server. One base and one
// request builder, so a new route does not need its own transport rules.

extension ServerModel {
    /// The daemon's HTTP base: scheme, host and port, no path.
    /// - WebSocket server: the server's own origin (`ws` becomes `http`, `wss` becomes `https`).
    /// - SSH server: `http://127.0.0.1:<port>` of the tunnel, read now, so a tunnel that moved is followed.
    ///   Throws `disconnected` while the tunnel is not up.
    /// - This Mac (`.local`): throws until the server is paired and saved as a WebSocket server (see
    ///   `AppModel.migrateLocalServers`).
    public func daemonHTTPBase() async throws -> URL {
        switch config.endpoint {
        case .webSocket(let server):
            guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
                throw RPCError(code: RPCError.invalidParams, message: "the server address is not usable")
            }
            components.scheme = ["wss", "https"].contains(components.scheme?.lowercased() ?? "") ? "https" : "http"
            components.path = ""
            components.percentEncodedQuery = nil
            components.fragment = nil
            guard let base = components.url else {
                throw RPCError(code: RPCError.invalidParams, message: "the server address is not usable")
            }
            return base
        case .ssh:
            guard let base = await transport?.httpBase else {
                throw RPCError(code: RPCError.disconnected, message: "the ssh tunnel is not up; connect the server first")
            }
            return base
        case .local:
            throw RPCError(
                code: RPCError.unsupportedTransport,
                message: "this Mac's server is not set up for the app yet; it is paired at the next launch")
        }
    }

    /// The request for a daemon route, with the device token as `Authorization: Bearer` (never in the URL).
    /// `query` values are percent-encoded so that `+`, `&`, `=`, `#` and `;` reach the daemon as data.
    /// `socket` makes the URL `ws` or `wss` for a WebSocket.
    /// The token needs TLS or loopback: a WebSocket server outside those throws `insecureTransport` instead of
    /// sending it in the clear. An ssh tunnel is loopback by construction.
    public func daemonRequest(
        path: String, query: [(name: String, value: String)] = [], socket: Bool = false
    ) async throws -> URLRequest {
        let base = try await daemonHTTPBase()
        if config.token != nil, !tokenMayTravel() {
            throw RPCError(
                code: RPCError.insecureTransport,
                message: "refusing to send the device token over an unencrypted connection")
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw RPCError(code: RPCError.invalidParams, message: "the server address is not usable")
        }
        let secure = ["https", "wss"].contains(components.scheme?.lowercased() ?? "")
        components.scheme = socket ? (secure ? "wss" : "ws") : (secure ? "https" : "http")
        components.path = path
        components.percentEncodedQuery =
            query.isEmpty
            ? nil
            : query.map { "\($0.name)=" + Self.queryEncoded($0.value) }.joined(separator: "&")
        components.fragment = nil
        guard let url = components.url else {
            throw RPCError(code: RPCError.invalidParams, message: "the request address is not usable")
        }
        var request = URLRequest(url: url)
        if let token = config.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Whether this server's token may leave the app: TLS or loopback, judged on the server's own address.
    private func tokenMayTravel() -> Bool {
        switch config.endpoint {
        case .webSocket(let server): WebSocketTransport.allowsToken(for: server)
        case .ssh: true
        case .local: false
        }
    }
}
