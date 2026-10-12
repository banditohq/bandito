import Foundation

/// Where an ssh server is, as the app keeps it: the host, the user and the port (both optional, as ssh defaults them),
/// and a key file. A saved server keeps these fields in `servers.v1`. A record from before the fields existed kept one
/// text, `[user@]host[:port]`; `ServerEndpoint` reads it into these fields.
public struct SSHServerAddress: Codable, Sendable, Hashable {
    public var host: String
    public var user: String?
    /// nil: ssh's own port (22, or what `~/.ssh/config` says for the host).
    public var port: Int?
    /// A private key file (`ssh -i`). nil: ssh chooses from its config and agent.
    public var identityFile: String?

    public init(host: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil) {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }

    /// The address of a `[user@]host[:port]` text (or an alias). nil when `SSHTarget` refuses the text.
    public init?(parsing text: String) {
        guard let target = SSHTarget.parse(text) else { return nil }
        self.init(host: target.host, user: target.user, port: target.port)
    }

    /// What ssh is given: the tunnel, the installer and scp read it.
    public var target: SSHTarget {
        SSHTarget(user: user, host: host, port: port, identityFile: identityFile)
    }

    /// `[user@]host[:port]`, without the key file: the text the old records kept.
    public var targetText: String {
        SSHTarget(user: user, host: host, port: port).description
    }

    /// A field of the connection form that ssh would refuse.
    public enum Problem: Error, Equatable, Sendable {
        case host, user, port, identityFile
    }

    /// Checks what the person typed into the form. Empty optional fields become nil. The host and the user are names
    /// (`SSHTarget.isSafeName`): letters, digits, dot, dash and underscore, never starting with a dash, so ssh can not
    /// read them as an option (`-oProxyCommand=…`). The host may also be an IPv6 address, bare or in brackets
    /// (`[2001:db8::1]`); it is kept without them. A key file must be an existing regular file (`isRegularFile`).
    public static func validated(
        host: String, user: String, port: String, identityFile: String?,
        isRegularFile: (String) -> Bool = SSHServerAddress.isRegularFile
    ) -> Result<SSHServerAddress, Problem> {
        var host = host.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            let inside = String(host.dropFirst().dropLast())
            guard SSHTarget.isIPv6Literal(inside) else { return .failure(.host) }
            host = inside
        }
        guard SSHTarget.isSafeHost(host) else { return .failure(.host) }

        let user = user.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty, !SSHTarget.isSafeName(user) { return .failure(.user) }

        let portText = port.trimmingCharacters(in: .whitespaces)
        var portValue: Int?
        if !portText.isEmpty {
            guard let value = Int(portText), (1...65_535).contains(value), portText.allSatisfy(\.isNumber) else {
                return .failure(.port)
            }
            portValue = value
        }

        let key = identityFile?.trimmingCharacters(in: .whitespaces)
        if let key, !key.isEmpty {
            guard isValidIdentityFile(key), isRegularFile(key) else { return .failure(.identityFile) }
        }

        return .success(
            SSHServerAddress(
                host: host, user: user.isEmpty ? nil : user, port: portValue,
                identityFile: (key?.isEmpty ?? true) ? nil : key))
    }

    /// Whether a path names an existing regular file: not a folder, not missing. A leading `~` is expanded, as ssh does.
    public static func isRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    /// Whether a key file path can be passed to ssh: not empty, not an option, no line break or NUL.
    public static func isValidIdentityFile(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("-") else { return false }
        return !path.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
    }
}
