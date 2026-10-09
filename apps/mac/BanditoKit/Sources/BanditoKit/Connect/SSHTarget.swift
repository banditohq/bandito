import Foundation

/// An ssh destination: `[user@]host[:port]`, or an alias from `~/.ssh/config`.
///
/// Only a conservative character set gets through. A target that starts with a dash would be read by
/// ssh as an option (`-oProxyCommand=…`), so it is refused here. IPv6 literals are not accepted yet.
public struct SSHTarget: Hashable, Sendable, CustomStringConvertible {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String?, host: String, port: Int?) {
        self.user = user
        self.host = host
        self.port = port
    }

    /// Parses what the user typed. Nil when it is empty, has spaces, or is not a plain host name.
    public static func parse(_ input: String) -> SSHTarget? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), !text.hasPrefix("-") else { return nil }

        let ats = text.filter { $0 == "@" }.count
        guard ats <= 1 else { return nil }
        var user: String?
        var rest = Substring(text)
        if ats == 1 {
            let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, isSafeName(String(parts[0])) else { return nil }
            user = String(parts[0])
            rest = parts[1]
        }

        var host = String(rest)
        var port: Int?
        let colons = host.filter { $0 == ":" }.count
        guard colons <= 1 else { return nil }
        if colons == 1, let colon = host.lastIndex(of: ":") {
            let portText = host[host.index(after: colon)...]
            guard !portText.isEmpty, portText.allSatisfy(\.isASCIIDigit), let value = Int(portText),
                (1...65_535).contains(value)
            else { return nil }
            port = value
            host = String(host[..<colon])
        }
        guard isSafeName(host) else { return nil }
        return SSHTarget(user: user, host: host, port: port)
    }

    /// `user@host:port` (or the alias with `:port`). This is the text a `ServerEndpoint.ssh` keeps.
    public var description: String {
        var text = destination
        if let port { text += ":\(port)" }
        return text
    }

    /// `user@host`, or the alias. What ssh and scp take as the host part.
    public var destination: String {
        user.map { "\($0)@\(host)" } ?? host
    }

    /// Arguments for ssh before the remote command: `-p N` when a port is set, then the destination.
    public var sshArguments: [String] {
        (port.map { ["-p", String($0)] } ?? []) + [destination]
    }

    /// Arguments for scp copying `local` to `remotePath` on this target (the port is `-P`).
    public func scpArguments(local: String, remotePath: String) -> [String] {
        (port.map { ["-P", String($0)] } ?? []) + [local, "\(destination):\(remotePath)"]
    }

    /// Letters, digits, dot, dash and underscore, not starting with a dash: safe as a host, alias or user name.
    static func isSafeName(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("-") else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
