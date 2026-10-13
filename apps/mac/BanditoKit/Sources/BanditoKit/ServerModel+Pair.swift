import Foundation

// Pairing another device with this server: `pair.create` makes a one-time code (docs/ARCHITECTURE.md#transports).

/// A one-time code for a new device. The code is good for `expiresInMs` (ten minutes today).
public struct PairCode: Codable, Sendable, Hashable {
    public var code: String
    public var expiresInMs: Int64
    /// The link for the iPhone app (`PhonePairLink`), also the text of the QR code. Nil while the phone listener is
    /// not up, and on daemons without the `phone_access` feature.
    public var link: String?
    /// The addresses in the link (`host:port`), best first.
    public var hosts: [String]?
    /// SHA-256 of the daemon's phone certificate, as in the link.
    public var fingerprint: String?
    /// `host/sid` of Bandito Relay when relay mode is on (the link's `relay`), else nil. Missing on older daemons.
    public var relay: String?
    /// The daemon's Noise public key (base64url) when relay mode is on (the link's `nk`).
    public var noiseKey: String?

    public init(
        code: String, expiresInMs: Int64, link: String? = nil, hosts: [String]? = nil, fingerprint: String? = nil,
        relay: String? = nil, noiseKey: String? = nil
    ) {
        self.code = code
        self.expiresInMs = expiresInMs
        self.link = link
        self.hosts = hosts
        self.fingerprint = fingerprint
        self.relay = relay
        self.noiseKey = noiseKey
    }
}

extension ServerModel {
    /// Creates a code that another device can redeem with `pair.redeem`.
    public func createPairCode() async throws -> PairCode {
        try await rpc().call("pair.create", NoParams(), as: PairCode.self)
    }
}

/// The link a pairing QR code carries: `bandito://pair?code=…&host=…`.
public enum PairLink {
    public static let scheme = "bandito"

    /// Both values are percent-encoded so that neither can add a parameter of its own.
    public static func url(code: String, host: String) -> String {
        "\(scheme)://pair?code=\(escape(code))&host=\(escape(host))"
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The link the iPhone app scans (docs/ARCHITECTURE.md#phone-access, docs/RELAY.md):
/// `bandito://pair?v=1&code=<words>&fp=<sha256 hex>&name=<server name>&host=<host:port>&host=<host:port>&relay=<host/sid>&nk=<base64url>`.
/// `host` repeats, best first (Tailscale, then the local network), IPv6 in square brackets. `relay` and `nk` are there when
/// the server's relay mode is on; then `fp` and `host` may be missing (relay only). Values are percent-encoded. The
/// daemon makes the link; the app checks it before it shows a QR code, so a broken one is never drawn.
public struct PhonePairLink: Sendable, Hashable {
    public static let version = 1
    public static let maxNameCharacters = 64

    public var code: String
    /// nil for a relay-only link.
    public var fingerprint: String?
    public var name: String
    public var hosts: [String]
    public var relay: RelayRoute?
    /// The daemon's Noise key, base64url.
    public var noiseKey: String?

    public init(
        code: String, fingerprint: String?, name: String, hosts: [String], relay: RelayRoute? = nil, noiseKey: String? = nil
    ) {
        self.code = code
        self.fingerprint = fingerprint
        self.name = name
        self.hosts = hosts
        self.relay = relay
        self.noiseKey = noiseKey
    }

    /// Why a link was refused.
    public enum Problem: Error, Sendable, Hashable {
        case notALink, unsupportedVersion, badCode, badFingerprint, noHosts, badRelay
    }

    /// The link text. The name is cut at 64 characters.
    public static func make(
        code: String, fingerprint: String?, name: String, hosts: [String], relay: RelayRoute? = nil, noiseKey: String? = nil
    ) -> String {
        var text = "\(PairLink.scheme)://pair?v=\(version)&code=\(escape(code))"
        if let fingerprint { text += "&fp=\(fingerprint)" }
        text += "&name=\(escape(String(name.prefix(maxNameCharacters))))"
        for host in hosts { text += "&host=\(escape(host))" }
        if let relay, let noiseKey { text += "&relay=\(escape(relay.host))/\(escape(relay.sid))&nk=\(escape(noiseKey))" }
        return text
    }

    /// Reads a link and checks it: version 1, a six-word code, a 64-digit lower-case hex fingerprint when there are hosts,
    /// at least one way in (a host with its fingerprint, or the relay with its key). Unknown parameters are ignored.
    public static func parse(_ text: String) throws -> PhonePairLink {
        guard let components = URLComponents(string: text), components.scheme == PairLink.scheme,
            components.host == "pair"
        else { throw Problem.notALink }
        let items = components.queryItems ?? []
        func first(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard first("v") == String(version) else { throw Problem.unsupportedVersion }
        guard let code = first("code"), code.split(separator: "-").count == 6,
            code.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") && !$0.isUppercase })
        else { throw Problem.badCode }
        var route: RelayRoute?
        var noiseKey: String?
        if first("relay") != nil || first("nk") != nil {
            guard let rawRelay = first("relay"), let parsed = RelayRoute.parse(rawRelay), let nk = first("nk"),
                Base64URL.key(nk) != nil
            else { throw Problem.badRelay }
            route = parsed
            noiseKey = nk
        }
        var fp: String?
        if let value = first("fp") {
            guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw Problem.badFingerprint }
            fp = value
        }
        var hosts = items.filter { $0.name == "host" }.compactMap(\.value).filter { !$0.isEmpty }
        // A host is only worth trying with the certificate to pin: without one the relay is the way.
        if fp == nil { hosts = [] }
        if route == nil {
            guard fp != nil else { throw Problem.badFingerprint }
            guard !hosts.isEmpty else { throw Problem.noHosts }
        }
        return PhonePairLink(
            code: code, fingerprint: fp, name: first("name") ?? "", hosts: hosts, relay: route, noiseKey: noiseKey)
    }

    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:")

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
