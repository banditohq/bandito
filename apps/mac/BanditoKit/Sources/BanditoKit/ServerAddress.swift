import Foundation

/// How a saved server is named in the UI: a short human address, never the id or the token.
public enum ServerAddress: Equatable, Sendable {
    /// The daemon on this Mac. The UI shows its localized "This Mac".
    case thisMac
    /// `user@host` for ssh, `host:port` for WebSocket. No scheme, no path, no port for ssh.
    case remote(String)

    public init(endpoint: ServerEndpoint) {
        switch endpoint {
        case .local:
            self = .thisMac
        case .ssh(let target, _):
            if let parsed = SSHTarget.parse(target) {
                self = .remote(parsed.user.map { "\($0)@\(parsed.host)" } ?? parsed.host)
            } else {
                self = .remote(target)
            }
        case .webSocket(let url):
            var host = url.host() ?? ""
            if host.contains(":"), !host.hasPrefix("[") {
                host = "[\(host)]"
            }
            if host.isEmpty {
                // Nothing to show that would not leak the path or the token: a dash.
                self = .remote("—")
            } else if let port = url.port {
                self = .remote("\(host):\(port)")
            } else {
                self = .remote(host)
            }
        }
    }
}
