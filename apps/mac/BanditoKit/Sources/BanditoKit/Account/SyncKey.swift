import CryptoKit
import Foundation

public enum SyncKeyError: Error, Equatable, Sendable {
    /// The public key is not a valid X25519 key, or HPKE refused it.
    case invalidPublicKey
    /// The envelope is not base64, or not exactly 113 bytes, or its version byte is not 0x02.
    /// Checked before any decryption.
    case invalidEnvelope
    /// The sealed blob is not base64.
    case malformedBlob
    /// The envelope or blob does not open with this key and data: wrong key, wrong sender, wrong
    /// associated data, or changed bytes.
    case cannotOpen
    /// A stored or opened key is not 256 bits.
    case invalidKey
    /// The code the user confirmed does not match the envelope's sender. The sync key is not released.
    case senderMismatch
}

/// A sync key from an envelope whose sender is not confirmed yet. The key is private: the only way out is
/// `accept(confirmedFingerprint:)`, which compares the sender's code with the one the user confirmed.
public struct PendingSyncKey: Sendable {
    /// The code of the device that sealed the envelope. The screen shows it, and the user compares it with
    /// the code of the approving device.
    public let senderFingerprint: String
    private let key: SymmetricKey

    init(key: SymmetricKey, senderFingerprint: String) {
        self.key = key
        self.senderFingerprint = senderFingerprint
    }

    /// The sync key, once `confirmedFingerprint` is the sender's code. Anything else is
    /// `SyncKeyError.senderMismatch`, and the key is not returned.
    public func accept(confirmedFingerprint: String) throws -> SymmetricKey {
        guard DeviceFingerprint.matches(senderFingerprint, confirmedFingerprint) else {
            throw SyncKeyError.senderMismatch
        }
        return key
    }
}

/// The account's sync key: 256 bits, made by the first approved device, handed to other devices in
/// envelopes, and used to seal the sync blob. The server never sees it.
///
/// Envelope, version 2 (docs/ACCOUNTS_API.md#encryption-model): standard base64 of 113 bytes:
/// `0x02 || sender_x25519_pub (32) || enc (32) || ct (48)`. HPKE base-mode-with-sender-auth (RFC 9180 `auth`
/// mode, suite `DHKEM(X25519)/HKDF-SHA256/ChaCha20-Poly1305`, `info` = `bandito-sync-key:v1`) seals the 32-byte
/// key. The associated data is `bandito-sync-key:v2:<accountID>:<newDeviceID>`, so an envelope opens only for
/// the device and account it was sealed for. `enc` is the encapsulated key, `ct` is the ciphertext with its
/// 16-byte tag. The sender's private key is the approving device's X25519 key: a successful open proves who
/// sealed the envelope, and `PendingSyncKey.accept` makes the user confirm that sender.
///
/// Blob format: standard base64 of ChaCha20-Poly1305 "combined" (12-byte nonce, ciphertext, 16-byte tag).
/// The associated data binds the blob to its account and version: see `blobAssociatedData`.
public enum SyncKey {
    /// Keychain account of the sync key (in the account store, see `AccountClient.sessionAccount`).
    public static let keychainAccount = "sync-key"

    static let info = Data("bandito-sync-key:v1".utf8)
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let envelopeVersion: UInt8 = 0x02
    static let publicKeyLength = 32
    static let encapsulatedKeyLength = 32
    /// 32-byte key plus the 16-byte ChaCha20-Poly1305 tag.
    static let sealedKeyLength = 48
    static let envelopeLength = 1 + publicKeyLength + encapsulatedKeyLength + sealedKeyLength

    /// The stored sync key, or nil when this device has none.
    public static func load(from store: SecretStore) throws -> SymmetricKey? {
        guard let raw = try store.load(account: keychainAccount) else { return nil }
        guard raw.count == 32 else { throw SyncKeyError.invalidKey }
        return SymmetricKey(data: raw)
    }

    /// Replaces the sync key with a new one: the old key is removed first, then a new one is made.
    /// Used after a reset, where the old key must not seal anything for the new account history.
    public static func rotate(in store: SecretStore) throws -> SymmetricKey {
        try store.save(nil, account: keychainAccount)
        return try loadOrCreate(from: store)
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

    /// The associated data of an envelope: `bandito-sync-key:v2:<accountID>:<deviceID>`, where `deviceID` is the
    /// device the envelope is sealed for.
    public static func envelopeAssociatedData(accountID: String, deviceID: String) -> Data {
        Data("bandito-sync-key:v2:\(accountID):\(deviceID)".utf8)
    }

    /// Seals `key` for the device `deviceID` of account `accountID`, whose X25519 public key is
    /// `publicKeyBase64`, as `sender` (this device). Only that device's private key opens it. The envelope
    /// carries the sender's public key, so `open` can report the sender's fingerprint.
    public static func seal(
        _ key: SymmetricKey, forPublicKey publicKeyBase64: String, sender: DeviceIdentity,
        accountID: String, deviceID: String
    ) throws -> String {
        let keyBytes = bytes(of: key)
        guard keyBytes.count == 32 else { throw SyncKeyError.invalidKey }
        guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == publicKeyLength,
            let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        else {
            throw SyncKeyError.invalidPublicKey
        }
        let aad = envelopeAssociatedData(accountID: accountID, deviceID: deviceID)
        let encapsulated: Data
        let sealed: Data
        do {
            var hpke = try HPKE.Sender(
                recipientKey: recipient, ciphersuite: suite, info: info, authenticatedBy: sender.agreementKey)
            sealed = try hpke.seal(keyBytes, authenticating: aad)
            encapsulated = hpke.encapsulatedKey
        } catch {
            throw SyncKeyError.invalidPublicKey
        }
        guard sealed.count == sealedKeyLength else { throw SyncKeyError.invalidKey }
        var envelope = Data([envelopeVersion])
        envelope.append(sender.agreementKey.publicKey.rawRepresentation)
        envelope.append(encapsulated)
        envelope.append(sealed)
        return envelope.base64EncodedString()
    }

    /// Opens a version 2 envelope that was sealed for `deviceID` of `accountID`, with this device's X25519
    /// private key. The result holds the sync key until `accept` confirms the sender's fingerprint.
    public static func open(
        envelope: String, with identity: DeviceIdentity, accountID: String, deviceID: String
    ) throws -> PendingSyncKey {
        guard let decoded = Data(base64Encoded: envelope) else { throw SyncKeyError.invalidEnvelope }
        let bytes = [UInt8](decoded)
        guard bytes.count == envelopeLength, bytes[0] == envelopeVersion else {
            throw SyncKeyError.invalidEnvelope
        }
        let senderRaw = Data(bytes[1..<33])
        let encapsulated = Data(bytes[33..<65])
        let ciphertext = Data(bytes[65..<113])
        guard let sender = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw) else {
            throw SyncKeyError.cannotOpen
        }
        let plaintext: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: identity.agreementKey, ciphersuite: suite, info: info,
                encapsulatedKey: encapsulated, authenticatedBy: sender)
            plaintext = try recipient.open(
                ciphertext, authenticating: envelopeAssociatedData(accountID: accountID, deviceID: deviceID))
        } catch {
            throw SyncKeyError.cannotOpen
        }
        guard plaintext.count == 32 else { throw SyncKeyError.invalidKey }
        return PendingSyncKey(
            key: SymmetricKey(data: plaintext), senderFingerprint: DeviceFingerprint.code(publicKey: senderRaw))
    }

    /// The associated data of a sync blob: `bandito-sync-blob:v1:<accountID>:<version>`, where `version` is
    /// the version the blob is stored under on the server. A blob moved to another account or version does
    /// not open.
    public static func blobAssociatedData(accountID: String, version: Int) -> Data {
        Data("bandito-sync-blob:v1:\(accountID):\(version)".utf8)
    }

    /// Seals a sync payload for the blob. Returns base64.
    public static func sealBlob(_ plaintext: Data, key: SymmetricKey, associatedData: Data) throws -> String {
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: associatedData)
        return box.combined.base64EncodedString()
    }

    public static func openBlob(_ blob: String, key: SymmetricKey, associatedData: Data) throws -> Data {
        guard let combined = Data(base64Encoded: blob) else { throw SyncKeyError.malformedBlob }
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            return try ChaChaPoly.open(box, using: key, authenticating: associatedData)
        } catch {
            throw SyncKeyError.cannotOpen
        }
    }

    private static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
