import CryptoKit
import Foundation

public enum DeviceTokenSealError: Error, Equatable, Sendable {
    /// The recipient's public key is not a valid X25519 key.
    case invalidPublicKey
    /// The sealed text is not base64, has the wrong size or version. Checked before any decryption.
    case invalidSeal
    /// The token is empty or too long to be one.
    case invalidToken
    /// It does not open: another device, account or server, a changed sender, or changed bytes.
    case cannotOpen
}

/// A grant that was opened: the device token, how to reach the daemon that issued it (the sealing device took that record from
/// the daemon itself, so it is the truth, unlike the hint in the account's blob), and the public key of the device that sealed it.
public struct OpenedDeviceToken: Sendable, Equatable {
    public let token: String
    /// The daemon's own answer to `phone.info`, as the sealing device read it when it issued the token.
    public let phone: SyncedPhone
    /// The sealing device's X25519 public key (base64), as written in the message. HPKE proved that its private half
    /// sealed this; whether it belongs to a device of the account is for the caller (`DeviceTokenSeal.open`).
    public let senderPublicKey: String
}

/// A daemon's device token, sealed to one device of the account (docs/RELAY.md, "One account on every device").
///
/// The same suite and mode as the sync key envelope (`SyncKey`): HPKE auth mode, `DHKEM(X25519)/HKDF-SHA256/
/// ChaCha20-Poly1305`, with the sender's X25519 key as `authenticatedBy`. `info` is `bandito-device-token:v2`, the
/// associated data is UTF-8 `<accountID>:<requestingDeviceID>:<serverID>`, so a message opens only for that device,
/// of that account, for that server. Wire form, standard base64 of `0x02 || sender_pub (32) || enc (32) || ct`,
/// where `ct` is the JSON `{"token": …, "phone": {sid, relay_host, nk, fp, hosts}}` with its 16-byte tag. The `phone`
/// record is what the daemon said about itself (`phone.info`): the address and the pins the requesting device connects
/// with come from here, never from the account's blob, which any device of the account can write. Version 1 (the token
/// alone) is not accepted.
public enum DeviceTokenSeal {
    static let info = Data("bandito-device-token:v2".utf8)
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let version: UInt8 = 0x02
    static let headerLength = 1 + 32 + 32
    static let tagLength = 16
    /// A device token is `bdt_` and 64 hex digits and the record is a few hundred bytes; the limit leaves room and no more.
    static let maxTokenLength = 4096

    /// The sealed text: the token and the daemon's record of how to reach it.
    struct Payload: Codable {
        var token: String
        var phone: SyncedPhone
    }

    /// The associated data: `<accountID>:<requestingDeviceID>:<serverID>`. The server id is lower case.
    public static func associatedData(accountID: String, deviceID: String, serverID: String) -> Data {
        Data("\(accountID):\(deviceID):\(AccessKey.normalized(serverID))".utf8)
    }

    /// Seals `token` for `deviceID` of `accountID`, whose X25519 public key is `publicKeyBase64`, as `sender` (this
    /// device). `serverID` is the server the token is for.
    public static func seal(
        token: String, phone: SyncedPhone, forPublicKey publicKeyBase64: String, sender: DeviceIdentity,
        accountID: String, deviceID: String, serverID: String
    ) throws -> String {
        var record = phone
        record.extras = [:]
        guard !token.isEmpty, record.isReachable, let plain = try? JSONEncoder().encode(Payload(token: token, phone: record)),
            plain.count <= maxTokenLength
        else { throw DeviceTokenSealError.invalidToken }
        guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == 32,
            let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        else {
            throw DeviceTokenSealError.invalidPublicKey
        }
        let aad = associatedData(accountID: accountID, deviceID: deviceID, serverID: serverID)
        var message = Data([version])
        message.append(sender.agreementKey.publicKey.rawRepresentation)
        do {
            var hpke = try HPKE.Sender(
                recipientKey: recipient, ciphersuite: suite, info: info, authenticatedBy: sender.agreementKey)
            let sealed = try hpke.seal(plain, authenticating: aad)
            message.append(hpke.encapsulatedKey)
            message.append(sealed)
        } catch {
            throw DeviceTokenSealError.invalidPublicKey
        }
        return message.base64EncodedString()
    }

    /// Opens a message sealed for this device (`identity`), `accountID` and `serverID`. `deviceID` is this device's id
    /// on the account.
    ///
    /// `expectedSenders` are the public keys of the account's devices, when the caller knows them. The message must
    /// then come from one of them; with nil, any sender HPKE accepts is returned and the caller decides (the blob that
    /// carried the message is already encrypted with the account's sync key, which only its devices hold).
    public static func open(
        sealed: String, with identity: DeviceIdentity, accountID: String, deviceID: String, serverID: String,
        expectedSenders: Set<String>? = nil
    ) throws -> OpenedDeviceToken {
        guard let decoded = Data(base64Encoded: sealed) else { throw DeviceTokenSealError.invalidSeal }
        let bytes = [UInt8](decoded)
        guard bytes.count > headerLength + tagLength, bytes[0] == version,
            bytes.count <= headerLength + tagLength + maxTokenLength
        else {
            throw DeviceTokenSealError.invalidSeal
        }
        let senderRaw = Data(bytes[1..<33])
        let encapsulated = Data(bytes[33..<65])
        let ciphertext = Data(bytes[65...])
        let senderBase64 = senderRaw.base64EncodedString()
        if let expectedSenders, !expectedSenders.contains(senderBase64) { throw DeviceTokenSealError.cannotOpen }
        guard let sender = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw) else {
            throw DeviceTokenSealError.cannotOpen
        }
        let plain: Data
        do {
            var recipient = try HPKE.Recipient(
                privateKey: identity.agreementKey, ciphersuite: suite, info: info,
                encapsulatedKey: encapsulated, authenticatedBy: sender)
            plain = try recipient.open(
                ciphertext, authenticating: associatedData(accountID: accountID, deviceID: deviceID, serverID: serverID))
        } catch {
            throw DeviceTokenSealError.cannotOpen
        }
        guard var payload = try? JSONDecoder().decode(Payload.self, from: plain), !payload.token.isEmpty,
            payload.phone.isReachable
        else {
            throw DeviceTokenSealError.invalidToken
        }
        payload.phone.extras = [:]
        return OpenedDeviceToken(token: payload.token, phone: payload.phone, senderPublicKey: senderBase64)
    }
}
