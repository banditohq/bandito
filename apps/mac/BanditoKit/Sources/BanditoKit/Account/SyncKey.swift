import CryptoKit
import Foundation

public enum SyncKeyError: Error, Equatable, Sendable {
    /// The public key is not a valid X25519 key.
    case invalidPublicKey
    /// The envelope is not base64, or too short to hold an encapsulated key.
    case malformedEnvelope
    /// The sealed blob is not base64.
    case malformedBlob
    /// The envelope or blob does not open with this key: wrong key, or the data was changed.
    case cannotOpen
    /// A stored or opened key is not 256 bits.
    case invalidKey
}

/// The account's sync key: 256 bits, made by the first approved device, handed to other devices in
/// envelopes, and used to seal the sync blob. The server never sees it.
///
/// Envelope format (docs/ACCOUNTS_API.md#encryption-model): standard base64 of
/// `enc || ciphertext`, where `enc` is the 32-byte X25519 encapsulated key of HPKE base mode
/// (RFC 9180, suite `Curve25519_SHA256_ChachaPoly`, `info` = `bandito-sync-key:v1`) and `ciphertext` is the
/// 32-byte key sealed with ChaCha20-Poly1305 (48 bytes with the tag). 80 bytes, about 108 characters.
/// The envelope is not signed, so the sender is not authenticated: see `seal` for the consequence.
///
/// Blob format: standard base64 of ChaCha20-Poly1305 "combined" (12-byte nonce, ciphertext, 16-byte tag).
public enum SyncKey {
    /// Keychain account of the sync key (in the account store, see `AccountClient.sessionAccount`).
    public static let keychainAccount = "sync-key"

    static let info = Data("bandito-sync-key:v1".utf8)
    static let encapsulatedKeyLength = 32
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    /// The stored sync key, or nil when this device has none.
    public static func load(from store: SecretStore) throws -> SymmetricKey? {
        guard let raw = try store.load(account: keychainAccount) else { return nil }
        guard raw.count == 32 else { throw SyncKeyError.invalidKey }
        return SymmetricKey(data: raw)
    }

    public static func save(_ key: SymmetricKey, to store: SecretStore) throws {
        try store.save(bytes(of: key), account: keychainAccount)
    }

    /// The stored key, or a new one saved to `store`. Only the first device of an account with no data may
    /// create a key: a second key cannot open the blob that already exists.
    public static func loadOrCreate(from store: SecretStore) throws -> SymmetricKey {
        if let key = try load(from: store) { return key }
        let key = SymmetricKey(size: .bits256)
        try save(key, to: store)
        return key
    }

    /// Seals `key` for the device whose X25519 public key is `publicKeyBase64`.
    ///
    /// HPKE base mode gives confidentiality and integrity against everyone but the holder of the
    /// recipient's private key. It does not authenticate the sender. A server that replaces an envelope can
    /// substitute its own key, so the approving device and the new device must compare a short code
    /// out of band before the envelope is used.
    public static func seal(_ key: SymmetricKey, forPublicKey publicKeyBase64: String) throws -> String {
        guard let raw = Data(base64Encoded: publicKeyBase64),
            let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        else {
            throw SyncKeyError.invalidPublicKey
        }
        do {
            var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info)
            let sealed = try sender.seal(bytes(of: key), authenticating: Data())
            return (sender.encapsulatedKey + sealed).base64EncodedString()
        } catch {
            throw SyncKeyError.invalidPublicKey
        }
    }

    /// Opens an envelope with this device's X25519 private key.
    public static func open(envelope: String, with identity: DeviceIdentity) throws -> SymmetricKey {
        guard let bytes = Data(base64Encoded: envelope), bytes.count > encapsulatedKeyLength else {
            throw SyncKeyError.malformedEnvelope
        }
        let encapsulated = Data(bytes.prefix(encapsulatedKeyLength))
        let ciphertext = Data(bytes.dropFirst(encapsulatedKeyLength))
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: identity.agreementKey, ciphersuite: suite, info: info,
                encapsulatedKey: encapsulated)
            plaintext = try recipient.open(ciphertext, authenticating: Data())
        } catch {
            throw SyncKeyError.cannotOpen
        }
        guard plaintext.count == 32 else { throw SyncKeyError.invalidKey }
        return SymmetricKey(data: plaintext)
    }

    /// Seals a sync payload for the blob. Returns base64.
    public static func sealBlob(_ plaintext: Data, key: SymmetricKey) throws -> String {
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return box.combined.base64EncodedString()
    }

    public static func openBlob(_ blob: String, key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: blob) else { throw SyncKeyError.malformedBlob }
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw SyncKeyError.cannotOpen
        }
    }

    private static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
