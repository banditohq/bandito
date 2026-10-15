import CryptoKit
import Foundation

/// The ticket of "Войти с помощью Mac". A signed-in Mac makes it and shows it as a QR code; a new iPhone scans the
/// code and redeems the ticket. The secret is only in the code. The cloud gets `authKey`, as a hash and as the token,
/// and never `macKey`, so it cannot make the proof of the Mac's key that the Mac checks (`JoinProof`).
public struct JoinTicket: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The longest name the link carries, in characters.
    public static let maxNameCharacters = 40

    /// 256 random bits. Only the QR code carries them.
    public let secret: SymmetricKey
    /// SHA-256 of the Mac's X25519 public key (the raw 32 bytes). The new device checks the sender of the sync-key
    /// envelope against it.
    public let macKeyHash: Data
    /// The Mac's name, for the new device to show. At most `maxNameCharacters` characters.
    public let macName: String

    public init(secret: SymmetricKey, macKeyHash: Data, macName: String) {
        self.secret = secret
        self.macKeyHash = macKeyHash
        self.macName = String(macName.prefix(Self.maxNameCharacters))
    }

    /// A new ticket for the Mac whose X25519 public key is `macPublicKey`. The secret is random.
    public static func make(macPublicKey: Curve25519.KeyAgreement.PublicKey, macName: String) -> JoinTicket {
        JoinTicket(
            secret: SymmetricKey(size: .bits256),
            macKeyHash: Data(SHA256.hash(data: macPublicKey.rawRepresentation)),
            macName: macName)
    }

    /// The key that authenticates the ticket to the cloud. It goes out only as `ticketHash` and `authToken`.
    public var authKey: Data {
        derived(info: "bandito-join:auth:v1")
    }

    /// The key of the Mac's proof. It never leaves the Mac and the new device.
    public var macKey: SymmetricKey {
        SymmetricKey(data: derived(info: "bandito-join:mac:v1"))
    }

    /// Lower-case hex of SHA-256(`authKey`): what the cloud stores (`POST /auth/ticket`).
    public var ticketHash: String {
        JoinCodec.hex(Data(SHA256.hash(data: authKey)))
    }

    /// `authKey` in base64url without padding: the `ticket` field of the redeem request.
    public var authToken: String {
        Base64URL.encode(authKey)
    }

    /// The link in the QR code: `bandito://join?v=1&t=<secret>&m=<macKeyHash>&n=<name>`. The name is percent-encoded
    /// and left out when empty.
    public var link: URL {
        var text = "bandito://join?v=1&t=\(Base64URL.encode(rawSecret))&m=\(Base64URL.encode(macKeyHash))"
        if !macName.isEmpty, let name = macName.addingPercentEncoding(withAllowedCharacters: Self.nameAllowed) {
            text += "&n=\(name)"
        }
        // Every part is base64url or percent-encoded, so the text is always a URL.
        guard let url = URL(string: text) else { preconditionFailure("join link is not a URL") }
        return url
    }

    /// The ticket of a join link, or nil. Only `bandito://join` with `v=1`, a 32-byte `t` and a 32-byte `m` is a
    /// ticket. `t` and `m` may be base64url or the standard alphabet, with or without padding. `n` is optional. Any
    /// other parameter, a repeated one, a path, a port or a fragment makes it nil.
    public static func parse(_ url: URL) -> JoinTicket? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "bandito", parts.host == "join",
            parts.path.isEmpty, parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil
        else { return nil }
        let items = parts.queryItems ?? []
        let names = items.map(\.name)
        guard Set(names).isSubset(of: ["v", "t", "m", "n"]), Set(names).count == names.count else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard value("v") == "1", let secretText = value("t"), let hashText = value("m"),
            let secret = JoinCodec.decode(secretText), secret.count == 32,
            let macKeyHash = JoinCodec.decode(hashText), macKeyHash.count == 32
        else { return nil }
        return JoinTicket(secret: SymmetricKey(data: secret), macKeyHash: macKeyHash, macName: value("n") ?? "")
    }

    /// The ticket of a join link text, or nil. See `parse(_ url: URL)`.
    public static func parse(_ text: String) -> JoinTicket? {
        guard let url = URL(string: text) else { return nil }
        return parse(url)
    }

    /// Whether the envelope was sealed by this Mac: the SHA-256 of its sender key is `macKeyHash`. The comparison
    /// is in constant time.
    public func isFromMac(envelope: Data) -> Bool {
        guard let sender = SyncKey.senderPublicKey(ofEnvelope: envelope) else { return false }
        return JoinCodec.equalInConstantTime(Data(SHA256.hash(data: sender)), macKeyHash)
    }

    /// The secret never appears in a description or a log.
    public var description: String {
        "JoinTicket(macName: \"\(macName)\")"
    }

    public var debugDescription: String {
        description
    }

    private var rawSecret: Data {
        secret.withUnsafeBytes { Data($0) }
    }

    private func derived(info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data(info.utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    /// Everything but these is percent-encoded, so a name cannot add a parameter of its own.
    private static let nameAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

/// The proof the new device sends with its ticket: an HMAC under the ticket's MAC key over the device's two public
/// keys.
/// Only the Mac and the new device hold the MAC key, so a valid proof shows that the device scanned this ticket's code.
public enum JoinProof {
    /// base64url without padding of HMAC-SHA256(`macKey`, "bandito-join-proof:v1:<publicKey>:<signingKey>").
    /// `publicKey` and `signingKey` are the base64 strings of the device block that goes to the cloud, unchanged.
    public static func make(macKey: SymmetricKey, publicKey: String, signingKey: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: message(publicKey: publicKey, signingKey: signingKey), using: macKey)
        return Base64URL.encode(Data(code))
    }

    /// Whether `proof` is the proof of these keys under `macKey`. The comparison is in constant time. Text that is not
    /// base64 is false.
    public static func verify(_ proof: String, macKey: SymmetricKey, publicKey: String, signingKey: String) -> Bool {
        guard let code = JoinCodec.decode(proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            code, authenticating: message(publicKey: publicKey, signingKey: signingKey), using: macKey)
    }

    private static func message(publicKey: String, signingKey: String) -> Data {
        Data("bandito-join-proof:v1:\(publicKey):\(signingKey)".utf8)
    }
}

extension SyncKey {
    /// The X25519 public key (32 bytes, bytes 1..<33) that sealed a version 2 envelope of the full length. Nil for
    /// another version or length.
    public static func senderPublicKey(ofEnvelope envelope: Data) -> Data? {
        let bytes = [UInt8](envelope)
        guard bytes.count == envelopeLength, bytes[0] == envelopeVersion else { return nil }
        return Data(bytes[1..<(1 + publicKeyLength)])
    }
}

/// The new device that redeemed a join ticket, as the cloud reports it (`GET /auth/ticket/:id`).
public struct ClaimedDevice: Sendable, Equatable, Decodable {
    public var id: String
    public var name: String
    public var platform: String
    /// The device's X25519 public key (base64).
    public var publicKey: String
    /// The device's Ed25519 signing key (base64).
    public var signingKey: String

    private enum CodingKeys: String, CodingKey {
        case id, name, platform
        case publicKey = "public_key"
        case signingKey = "signing_key"
    }
}

/// Where a join ticket stands on the server.
public enum TicketStatus: Sendable, Equatable {
    /// Nobody has scanned it yet.
    case open
    /// Its time ran out.
    case expired
    /// Just redeemed: the new device is being linked to the account. The Mac keeps waiting.
    case claiming
    /// A new device redeemed it. `proof` is that device's `JoinProof`; the Mac checks it before it approves the device.
    case claimed(device: ClaimedDevice, proof: String)
}

/// Encoding helpers shared by the join ticket and its proof. Not public.
enum JoinCodec {
    /// base64url, or the standard alphabet, with or without padding. Nil for anything else.
    static func decode(_ text: String) -> Data? {
        let unified = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return Base64URL.decode(unified.trimmingCharacters(in: CharacterSet(charactersIn: "=")))
    }

    /// Lower-case hex.
    static func hex(_ data: Data) -> String {
        data.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    /// Compares every byte, so the time does not depend on where the first difference is.
    static func equalInConstantTime(_ first: Data, _ second: Data) -> Bool {
        guard first.count == second.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(first, second) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
