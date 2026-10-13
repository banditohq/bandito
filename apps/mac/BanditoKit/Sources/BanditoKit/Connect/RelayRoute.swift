import Foundation

// Where Bandito Relay (docs/RELAY.md) reaches a server: the relay's host and the server's id, plus the daemon's Noise key
// that the phone pins. They come from the pairing link (`relay=<host[:port]>/<sid>&nk=<base64url>`).

/// The relay host and the server's relay id: `relay.bandito.dev/abcdefghijklmnopqrstuvwxyz`.
public struct RelayRoute: Sendable, Hashable, Codable {
    /// `host` or `host:port` (an IPv6 address in brackets).
    public var host: String
    /// 26 lower-case base32 characters.
    public var sid: String

    public init(host: String, sid: String) {
        self.host = host
        self.sid = sid
    }

    public static let sidLength = 26

    /// Reads `host[:port]/sid`. nil for anything else: no path beyond the id, no user, scheme or space.
    public static func parse(_ text: String) -> RelayRoute? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let host = DirectHost.parse(String(parts[0]), defaultPort: 443), isSID(String(parts[1])) else {
            return nil
        }
        return RelayRoute(host: host.port == 443 ? host.host : host.text, sid: String(parts[1]))
    }

    public static func isSID(_ text: String) -> Bool {
        text.count == sidLength && text.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 50 && $0 <= 55) }
    }

    /// The link's `relay` parameter.
    public var param: String { "\(host)/\(sid)" }

    /// The phone's WebSocket address. TLS always, except for this machine's own loopback (tests, local development).
    public var clientURL: URL? {
        guard let parsed = DirectHost.parse(host, defaultPort: 443) else { return nil }
        let local = ["127.0.0.1", "::1", "localhost"].contains(parsed.host)
        return URL(string: "\(local ? "ws" : "wss")://\(parsed.text)/v1/client/\(sid)")
    }

    /// What a person sees: the relay's name only when it is not Bandito's own.
    public var isBandito: Bool { host == "relay.bandito.dev" || host.hasSuffix(".bandito.dev") }
}

/// base64url without padding, the form of Noise keys in links and RPC.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// A 32-byte key in its canonical spelling, or nil.
    public static func key(_ text: String) -> Data? {
        guard let data = decode(text), data.count == 32, encode(data) == text else { return nil }
        return data
    }
}

/// How a connected server is being reached right now.
public enum ConnectionRoute: Sendable, Hashable {
    /// A direct address: the local network, Tailscale.
    case network
    /// Through Bandito Relay.
    case cloud
}

/// A transport that knows which way it got through.
public protocol RouteReporting: Sendable {
    var connectedRoute: ConnectionRoute? { get async }
}
