import CryptoKit
import Foundation

extension ServerEndpoint {
    /// The direct addresses and the certificate pin, when the server has them.
    public var directPart: (hosts: [String], fingerprint: String)? {
        switch self {
        case .direct(let hosts, let fingerprint): return (hosts, fingerprint)
        case .reachable(let hosts, let fingerprint, _, _):
            guard !hosts.isEmpty, let fingerprint else { return nil }
            return (hosts, fingerprint)
        default: return nil
        }
    }

    /// The relay, with the daemon's Noise key, when the server has them.
    public var relayPart: (route: RelayRoute, noiseKey: Data)? {
        guard case .reachable(_, _, let route?, let key?) = self, let data = Base64URL.key(key) else { return nil }
        return (route, data)
    }

    /// Whether this is a server paired from a link (direct, relay or both): the kind with a device token.
    public var isPaired: Bool { directPart != nil || relayPart != nil }

    /// The certificate pin, when there is one.
    public var pinnedFingerprint: String? { directPart?.fingerprint }

    /// The daemon's Noise key (base64url), when there is one.
    public var noiseKeyText: String? {
        if case .reachable(_, _, _, let key) = self { return key }
        return nil
    }

    /// Whether `other` is the same server: every identifier that both have (the certificate, the Noise key) agrees, and at
    /// least one is shared. A server paired once through the cloud and again over Tailscale is one server; the same
    /// certificate with another Noise key is not (`conflicts(with:)`).
    public func isSameServer(as other: ServerEndpoint) -> Bool {
        var shared = false
        for (a, b) in [(pinnedFingerprint, other.pinnedFingerprint), (noiseKeyText, other.noiseKeyText)] {
            guard let a, let b else { continue }
            if a != b { return false }
            shared = true
        }
        return shared
    }

    /// Whether `other` shares one identifier with this endpoint and differs in another: a different server behind the same
    /// certificate (or key). It is neither replaced nor added silently.
    public func conflicts(with other: ServerEndpoint) -> Bool {
        let pairs = [(pinnedFingerprint, other.pinnedFingerprint), (noiseKeyText, other.noiseKeyText)]
        var same = false, differs = false
        for (a, b) in pairs {
            guard let a, let b else { continue }
            if a == b { same = true } else { differs = true }
        }
        return same && differs
    }
}

extension ServerConfig {
    /// This device's relay key, when it has one.
    public var noisePrivateKey: Curve25519.KeyAgreement.PrivateKey? {
        guard let noiseSecret, let data = Base64URL.key(noiseSecret) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// How a new key for a server is spelled in `noiseSecret`.
    public static func newNoiseSecret() -> (secret: String, publicKey: String) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (Base64URL.encode(key.rawRepresentation), Base64URL.encode(key.publicKey.rawRepresentation))
    }
}
