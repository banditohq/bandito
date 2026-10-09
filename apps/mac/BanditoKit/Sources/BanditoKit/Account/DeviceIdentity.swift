import CryptoKit
import Foundation

public enum DeviceIdentityError: Error, Sendable, Equatable, LocalizedError {
    /// A stored device key is not a valid key of its type. `reset()` removes both keys; then sign in again.
    case corruptKey

    public var errorDescription: String? {
        switch self {
        case .corruptKey:
            return "The stored device key is damaged. Reset this Mac's device keys and sign in again."
        }
    }
}

/// The two keys of this device. X25519 receives sync-key envelopes; Ed25519 identifies the device on
/// the account and signs every sign-in. Private halves stay in the Keychain on this Mac.
/// See docs/ACCOUNTS_API.md#device-identity. Load it through `DeviceIdentityStore`.
public struct DeviceIdentity: Sendable {
    /// Keychain service of the device keys (accounts `x25519` and `ed25519`).
    public static let keychainService = "dev.bandito.device"
    static let agreementAccount = "x25519"
    static let signingAccount = "ed25519"

    /// X25519 private key: opens envelopes sealed to this device, and authenticates the envelopes it seals.
    let agreementKey: Curve25519.KeyAgreement.PrivateKey
    private let signingKey: Curve25519.Signing.PrivateKey

    private init(agreementKey: Curve25519.KeyAgreement.PrivateKey, signingKey: Curve25519.Signing.PrivateKey) {
        self.agreementKey = agreementKey
        self.signingKey = signingKey
    }

    /// Reads both keys from `store` and creates whichever is missing. A stored key of the wrong length is
    /// `DeviceIdentityError.corruptKey`: it is never replaced silently.
    static func make(from store: SecretStore) throws -> DeviceIdentity {
        let agreement: Curve25519.KeyAgreement.PrivateKey
        if let raw = try store.load(account: agreementAccount) {
            guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
                throw DeviceIdentityError.corruptKey
            }
            agreement = key
        } else {
            agreement = Curve25519.KeyAgreement.PrivateKey()
            try store.save(agreement.rawRepresentation, account: agreementAccount)
        }

        let signing: Curve25519.Signing.PrivateKey
        if let raw = try store.load(account: signingAccount) {
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
                throw DeviceIdentityError.corruptKey
            }
            signing = key
        } else {
            signing = Curve25519.Signing.PrivateKey()
            try store.save(signing.rawRepresentation, account: signingAccount)
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

    /// The code of this device's X25519 key (`DeviceFingerprint`). The new device shows it to the user.
    public var fingerprint: String {
        DeviceFingerprint.code(publicKey: agreementKey.publicKey.rawRepresentation)
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

/// Loads this device's identity once. The actor serializes the first load, so concurrent callers get the
/// same key pair and never create two.
public actor DeviceIdentityStore {
    private let secrets: SecretStore
    private var loaded: DeviceIdentity?

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    /// The device identity, created on first use.
    public func load() throws -> DeviceIdentity {
        if let loaded { return loaded }
        let identity = try DeviceIdentity.make(from: secrets)
        loaded = identity
        return identity
    }

    /// Removes both device keys. The next `load` creates new ones, so this device must sign in again and
    /// be approved as a new device.
    public func reset() throws {
        try secrets.save(nil, account: DeviceIdentity.agreementAccount)
        try secrets.save(nil, account: DeviceIdentity.signingAccount)
        loaded = nil
    }
}
