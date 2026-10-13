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

    /// Whether `other` is the same server: the same certificate, or the same Noise key. A server paired once through the
    /// cloud and again over Tailscale is one server.
    public func isSameServer(as other: ServerEndpoint) -> Bool {
        if let a = pinnedFingerprint, let b = other.pinnedFingerprint, a == b { return true }
        if let a = noiseKeyText, let b = other.noiseKeyText, a == b { return true }
        return false
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
