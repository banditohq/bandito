import Foundation

/// An ssh destination: `[user@]host[:port]`, or an alias from `~/.ssh/config`.
///
/// Only a conservative character set gets through. A target that starts with a dash would be read by
/// ssh as an option (`-oProxyCommand=…`), so it is refused here. An IPv6 address is taken in brackets
/// (`[2001:db8::1]`, `user@[2001:db8::1]:2222`) or bare without a port (`2001:db8::1`); it is kept bare in `host`
/// and put back in brackets wherever ssh and scp need them (a port after it, scp's `host:path`).
public struct SSHTarget: Hashable, Sendable, CustomStringConvertible {
    public var user: String?
    public var host: String
    public var port: Int?
    /// A private key file for ssh (`-i`). nil leaves the choice to ssh and its config.
    public var identityFile: String?

    public init(user: String?, host: String, port: Int?, identityFile: String? = nil) {
        self.user = user
        self.host = host
        self.port = port
        self.identityFile = identityFile
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
        // An IPv6 address: in brackets, with a port after them or not; or bare, then without a port.
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let inside = String(host[host.index(after: host.startIndex)..<close])
            let after = host[host.index(after: close)...]
            guard isIPv6Literal(inside) else { return nil }
            if !after.isEmpty {
                guard after.hasPrefix(":"), let value = Self.port(after.dropFirst()) else { return nil }
                port = value
            }
            return SSHTarget(user: user, host: inside, port: port)
        }
        if isIPv6Literal(host) { return SSHTarget(user: user, host: host, port: nil) }
        let colons = host.filter { $0 == ":" }.count
        guard colons <= 1 else { return nil }
        if colons == 1, let colon = host.lastIndex(of: ":") {
            guard let value = Self.port(host[host.index(after: colon)...]) else { return nil }
            port = value
            host = String(host[..<colon])
        }
        guard isSafeName(host) else { return nil }
        return SSHTarget(user: user, host: host, port: port)
    }

    /// A port: digits only, 1…65535.
    private static func port(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit), let value = Int(text), (1...65_535).contains(value) else {
            return nil
        }
        return value
    }

    /// `user@host:port` (or the alias with `:port`; an IPv6 address in brackets). This is the text a
    /// `ServerEndpoint.ssh` keeps, and `parse` reads it back.
    public var description: String {
        let address = isIPv6 ? "[\(host)]" : host
        var text = user.map { "\($0)@\(address)" } ?? address
        if let port { text += ":\(port)" }
        return text
    }

    /// `user@host`, or the alias. What ssh takes as the destination (a bare IPv6 address is fine there: the port goes
    /// in `-p`).
    public var destination: String {
        user.map { "\($0)@\(host)" } ?? host
    }

    /// The host is an IPv6 address (kept without brackets).
    public var isIPv6: Bool { Self.isIPv6Literal(host) }

    /// Arguments for ssh before the remote command: `-i FILE` and `-p N` when they are set, then `--` and the
    /// destination. The `--` ends the options, so a destination can never be read as one (`-oProxyCommand=…`).
    public var sshArguments: [String] {
        (identityFile.map { ["-i", $0] } ?? []) + (port.map { ["-p", String($0)] } ?? []) + ["--", destination]
    }

    /// Arguments for scp copying `local` to `remotePath` on this target (the port is `-P`).
    public func scpArguments(local: String, remotePath: String) -> [String] {
        (identityFile.map { ["-i", $0] } ?? []) + (port.map { ["-P", String($0)] } ?? [])
            + ["--", local, "\(scpHost):\(remotePath)"]
    }

    /// scp's `host` before `:path`: an IPv6 address must be in brackets there, or its colons would end the host.
    private var scpHost: String {
        let address = isIPv6 ? "[\(host)]" : host
        return user.map { "\($0)@\(address)" } ?? address
    }

    /// Letters, digits, dot, dash and underscore, not starting with a dash: safe as a host, alias or user name.
    static func isSafeName(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("-") else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// A host ssh may be given: a safe name, or an IPv6 address without brackets.
    static func isSafeHost(_ text: String) -> Bool { isSafeName(text) || isIPv6Literal(text) }

    /// An IPv6 address as the system reads one (`inet_pton`), with an optional zone (`fe80::1%en0`, the zone a safe
    /// name). Hex digits, colons and dots only: nothing ssh could read as an option or a shell could split.
    static func isIPv6Literal(_ text: String) -> Bool {
        var address = Substring(text)
        if let percent = text.firstIndex(of: "%") {
            guard isSafeName(String(text[text.index(after: percent)...])) else { return false }
            address = text[..<percent]
        }
        guard address.contains(":"), address.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") })
        else { return false }
        var storage = in6_addr()
        return String(address).withCString { inet_pton(AF_INET6, $0, &storage) } == 1
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
