import CryptoKit
import Foundation

/// The two keys of this device. X25519 receives sync-key envelopes; Ed25519 identifies the device on
/// the account and signs every sign-in. Private halves stay in the Keychain on this Mac.
/// See docs/ACCOUNTS_API.md#device-identity.
public struct DeviceIdentity: Sendable {
    /// Keychain service of the device keys (accounts `x25519` and `ed25519`).
    public static let keychainService = "dev.bandito.device"

    /// Opens sync-key envelopes sealed to `publicKeyBase64`.
    let agreementKey: Curve25519.KeyAgreement.PrivateKey
    private let signingKey: Curve25519.Signing.PrivateKey

    /// Loads both keys from `store`, creating whichever is missing.
    public static func load(from store: SecretStore) throws -> DeviceIdentity {
        let agreement: Curve25519.KeyAgreement.PrivateKey
        if let raw = try store.load(account: "x25519") {
            agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        } else {
            agreement = Curve25519.KeyAgreement.PrivateKey()
            try store.save(agreement.rawRepresentation, account: "x25519")
        }

        let signing: Curve25519.Signing.PrivateKey
        if let raw = try store.load(account: "ed25519") {
            signing = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        } else {
            signing = Curve25519.Signing.PrivateKey()
            try store.save(signing.rawRepresentation, account: "ed25519")
        }
        return DeviceIdentity(agreementKey: agreement, signingKey: signing)
    }

    /// Raw X25519 public key (32 bytes, base64). Sent as `public_key`.
    public var publicKeyBase64: String {
        agreementKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Raw Ed25519 public key (32 bytes, base64). Sent as `signing_key`.
    public var signingKeyBase64: String {
        signingKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// The signature for a sign-in with `nonce` (base64, 64 bytes), over `loginMessage`.
    public func sign(login nonce: String) -> String {
        let message = Self.loginMessage(
            nonce: nonce, publicKey: publicKeyBase64, signingKey: signingKeyBase64)
        // Ed25519 signing with a valid private key does not fail.
        let signature = try! signingKey.signature(for: Data(message.utf8))
        return signature.base64EncodedString()
    }

    /// The exact text the server verifies: `bandito-login:v1:<nonce>:<public_key>:<signing_key>`.
    public static func loginMessage(nonce: String, publicKey: String, signingKey: String) -> String {
        "bandito-login:v1:\(nonce):\(publicKey):\(signingKey)"
    }
}
