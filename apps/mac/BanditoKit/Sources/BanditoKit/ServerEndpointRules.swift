import Foundation

/// The changes the Connection section makes to a server's address, as pure rules, so the tests can hold them.
public enum ServerEndpointRules {
    /// The endpoint with its ssh address replaced. The daemon's port on the server stays as it was. nil for an endpoint
    /// that is not ssh.
    public static func replacingSSH(_ endpoint: ServerEndpoint, with server: SSHServerAddress) -> ServerEndpoint? {
        guard case .ssh(_, let remotePort) = endpoint else { return nil }
        return .ssh(server: server, remotePort: remotePort)
    }

    /// The WebSocket address the person typed: an absolute `ws://` or `wss://` URL with a host. nil otherwise.
    public static func webSocketURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            scheme == "ws" || scheme == "wss", let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Whether the address can be changed in the app. The daemon on this Mac has its socket, which is not typed.
    public static func isEditable(_ endpoint: ServerEndpoint) -> Bool {
        switch endpoint {
        case .local: false
        case .webSocket, .ssh: true
        // The pin and the addresses come from a pairing link, not from a typed address.
        case .direct: false
        }
    }
}
