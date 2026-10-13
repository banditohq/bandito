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

    public init(
        code: String, expiresInMs: Int64, link: String? = nil, hosts: [String]? = nil, fingerprint: String? = nil
    ) {
        self.code = code
        self.expiresInMs = expiresInMs
        self.link = link
        self.hosts = hosts
        self.fingerprint = fingerprint
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

/// The link the iPhone app scans (docs/ARCHITECTURE.md#phone-access):
/// `bandito://pair?v=1&code=<words>&fp=<sha256 hex>&name=<server name>&host=<host:port>&host=<host:port>`.
/// `host` repeats, best first (Tailscale, then the local network), IPv6 in square brackets. Values are
/// percent-encoded. The daemon makes the link; the app checks it before it shows a QR code, so a broken one is never
/// drawn.
public struct PhonePairLink: Sendable, Hashable {
    public static let version = 1
    public static let maxNameCharacters = 64

    public var code: String
    public var fingerprint: String
    public var name: String
    public var hosts: [String]

    /// Why a link was refused.
    public enum Problem: Error, Sendable, Hashable {
        case notALink, unsupportedVersion, badCode, badFingerprint, noHosts
    }

    /// The link text. The name is cut at 64 characters.
    public static func make(code: String, fingerprint: String, name: String, hosts: [String]) -> String {
        var text = "\(PairLink.scheme)://pair?v=\(version)&code=\(escape(code))&fp=\(fingerprint)"
        text += "&name=\(escape(String(name.prefix(maxNameCharacters))))"
        for host in hosts { text += "&host=\(escape(host))" }
        return text
    }

    /// Reads a link and checks it: version 1, a six-word code, a 64-digit lower-case hex fingerprint, at least one host.
    /// Unknown parameters are ignored.
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
        guard let fp = first("fp"), fp.count == 64, fp.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw Problem.badFingerprint
        }
        let hosts = items.filter { $0.name == "host" }.compactMap(\.value).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { throw Problem.noHosts }
        return PhonePairLink(code: code, fingerprint: fp, name: first("name") ?? "", hosts: hosts)
    }

    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:")

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
