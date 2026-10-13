import CryptoKit
import Foundation

// Noise_IK_25519_ChaChaPoly_SHA256 (Noise protocol framework, revision 34) for Bandito Relay (docs/RELAY.md). The phone is
// the initiator and knows the daemon's static key `nk` from the pairing link; the daemon is the responder. Only what the
// phone needs is here; the test target holds a responder that checks it. The bytes are checked against vectors made by
// `snow`, the library the daemon runs (`daemon/tests/relay_noise_vectors.rs`).

public enum NoiseError: Error, Sendable, Equatable {
    /// A key that is not 32 bytes, or a point the curve refuses.
    case badKey
    /// A handshake message of the wrong size, or one that does not decrypt: the other side is not who the link named.
    case handshakeFailed
    /// A transport message that does not decrypt (wrong key, tampered, replayed or out of order).
    case decryptFailed
    /// A message over 65535 bytes.
    case tooLarge
    /// The nonce counter ran out.
    case exhausted
}

public enum NoiseIK {
    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    public static let prologue = Data("bandito-relay-v1".utf8)
    /// The largest Noise message, ciphertext included.
    public static let maxMessage = 65535
    public static let tagSize = 16
    public static let keySize = 32

    /// The bytes of a Curve25519 private key made at random.
    public static func newPrivateKey() -> Curve25519.KeyAgreement.PrivateKey { Curve25519.KeyAgreement.PrivateKey() }
}

/// The symmetric state of Noise: chaining key, hash, and the cipher with its counter.
struct NoiseSymmetric {
    private(set) var ck: Data
    private(set) var h: Data
    private var k: SymmetricKey?
    private var n: UInt64 = 0

    init(protocolName: String, prologue: Data) {
        let name = Data(protocolName.utf8)
        // The name is longer than the hash (32): it is hashed.
        let initial = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = initial
        h = initial
        mixHash(prologue)
    }

    mutating func mixHash(_ data: Data) {
        var hasher = SHA256()
        hasher.update(data: h)
        hasher.update(data: data)
        h = Data(hasher.finalize())
    }

    mutating func mixKey(_ input: Data) {
        let out = Self.hkdf(chainingKey: ck, input: input, outputs: 2)
        ck = out[0]
        k = SymmetricKey(data: out[1])
        n = 0
    }

    mutating func encryptAndHash(_ plain: Data) throws -> Data {
        guard let key = k else {
            mixHash(plain)
            return plain
        }
        let sealed = try Self.seal(plain, key: key, counter: n, aad: h)
        n += 1
        mixHash(sealed)
        return sealed
    }

    mutating func decryptAndHash(_ cipher: Data) throws -> Data {
        guard let key = k else {
            mixHash(cipher)
            return cipher
        }
        let plain: Data
        do { plain = try Self.open(cipher, key: key, counter: n, aad: h) } catch { throw NoiseError.handshakeFailed }
        n += 1
        mixHash(cipher)
        return plain
    }

    /// The two transport keys: the first for what the initiator sends.
    func split() -> (Data, Data) {
        let out = Self.hkdf(chainingKey: ck, input: Data(), outputs: 2)
        return (out[0], out[1])
    }

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise's HKDF with HMAC-SHA256: up to three outputs.
    static func hkdf(chainingKey: Data, input: Data, outputs: Int) -> [Data] {
        let temp = hmac(chainingKey, input)
        var out: [Data] = [hmac(temp, Data([1]))]
        if outputs >= 2 { out.append(hmac(temp, out[0] + Data([2]))) }
        if outputs >= 3 { out.append(hmac(temp, out[1] + Data([3]))) }
        return out
    }

    /// The 96-bit nonce of ChaCha20-Poly1305 in Noise: four zero bytes, then the counter as 64 bits little-endian.
    static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        var le = counter.littleEndian
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    static func seal(_ plain: Data, key: SymmetricKey, counter: UInt64, aad: Data) throws -> Data {
        guard counter != UInt64.max else { throw NoiseError.exhausted }
        let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce(counter), authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ cipher: Data, key: SymmetricKey, counter: UInt64, aad: Data) throws -> Data {
        guard counter != UInt64.max else { throw NoiseError.exhausted }
        guard cipher.count >= NoiseIK.tagSize else { throw NoiseError.decryptFailed }
        let body = Data(cipher.prefix(cipher.count - NoiseIK.tagSize))
        let tag = Data(cipher.suffix(NoiseIK.tagSize))
        let box = try ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: body, tag: tag)
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}

/// The phone's side of the handshake. Single use: message 1, then message 2, then the transport.
public struct NoiseInitiator {
    private var symmetric: NoiseSymmetric
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let remoteStatic: Curve25519.KeyAgreement.PublicKey
    private var sent = false

    /// - Parameters:
    ///   - staticKey: this phone's key for the server.
    ///   - remoteStatic: the daemon's public key (`nk` of the link), 32 bytes.
    ///   - ephemeral: only for the test vectors; a real handshake makes its own.
    public init(
        staticKey: Curve25519.KeyAgreement.PrivateKey, remoteStatic: Data, prologue: Data = NoiseIK.prologue,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws {
        guard remoteStatic.count == NoiseIK.keySize,
            let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStatic)
        else { throw NoiseError.badKey }
        self.staticKey = staticKey
        self.remoteStatic = remote
        self.ephemeral = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        symmetric = NoiseSymmetric(protocolName: NoiseIK.protocolName, prologue: prologue)
        // `<- s`: the responder's static key is known before the first message.
        symmetric.mixHash(remoteStatic)
    }

    /// `-> e, es, s, ss` with `payload`.
    public mutating func writeMessage1(payload: Data) throws -> Data {
        precondition(!sent, "message 1 is written once")
        sent = true
        let e = ephemeral.publicKey.rawRepresentation
        symmetric.mixHash(e)
        symmetric.mixKey(try Self.dh(ephemeral, remoteStatic))
        let s = try symmetric.encryptAndHash(staticKey.publicKey.rawRepresentation)
        symmetric.mixKey(try Self.dh(staticKey, remoteStatic))
        let body = try symmetric.encryptAndHash(payload)
        let message = e + s + body
        guard message.count <= NoiseIK.maxMessage else { throw NoiseError.tooLarge }
        return message
    }

    /// `<- e, ee, se`: the daemon's answer. Returns its payload and the transport.
    public mutating func readMessage2(_ message: Data) throws -> (payload: Data, transport: NoiseTransport) {
        guard sent, message.count >= NoiseIK.keySize + NoiseIK.tagSize, message.count <= NoiseIK.maxMessage else {
            throw NoiseError.handshakeFailed
        }
        let re = Data(message.prefix(NoiseIK.keySize))
        guard let remoteEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: re) else {
            throw NoiseError.handshakeFailed
        }
        symmetric.mixHash(re)
        symmetric.mixKey(try Self.dh(ephemeral, remoteEphemeral))
        symmetric.mixKey(try Self.dh(staticKey, remoteEphemeral))
        let payload = try symmetric.decryptAndHash(Data(message.dropFirst(NoiseIK.keySize)))
        let (send, receive) = symmetric.split()
        return (payload, NoiseTransport(send: SymmetricKey(data: send), receive: SymmetricKey(data: receive)))
    }

    static func dh(_ private_: Curve25519.KeyAgreement.PrivateKey, _ public_: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let shared: Data
        do {
            let secret = try private_.sharedSecretFromKeyAgreement(with: public_)
            shared = secret.withUnsafeBytes { Data($0) }
        } catch {
            throw NoiseError.handshakeFailed
        }
        // A low-order point (all-zero output) would give both sides a key an eavesdropper can guess: refused.
        var accumulated: UInt8 = 0
        for byte in shared { accumulated |= byte }
        guard accumulated != 0 else { throw NoiseError.handshakeFailed }
        return shared
    }
}

/// The two directions of a finished session. Each message has its own counter, so a repeated or dropped message fails.
public struct NoiseTransport {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(send: SymmetricKey, receive: SymmetricKey) {
        sendKey = send
        receiveKey = receive
    }

    /// Encrypts one message (at most 65535 bytes with its tag).
    public mutating func encrypt(_ plain: Data) throws -> Data {
        guard plain.count + NoiseIK.tagSize <= NoiseIK.maxMessage else { throw NoiseError.tooLarge }
        let cipher = try NoiseSymmetric.seal(plain, key: sendKey, counter: sendCounter, aad: Data())
        sendCounter += 1
        return cipher
    }

    /// Decrypts the next message. A failure leaves the counter where it was, but the session is over after one anyway.
    public mutating func decrypt(_ cipher: Data) throws -> Data {
        guard cipher.count <= NoiseIK.maxMessage else { throw NoiseError.tooLarge }
        let plain: Data
        do { plain = try NoiseSymmetric.open(cipher, key: receiveKey, counter: receiveCounter, aad: Data()) } catch let e as NoiseError {
            throw e
        } catch { throw NoiseError.decryptFailed }
        receiveCounter += 1
        return plain
    }
}

/// How an RPC frame becomes Noise messages: `[u8 more][chunk]`, each message at most 65535 bytes with its tag.
public enum NoiseFraming {
    public static let chunkSize = NoiseIK.maxMessage - NoiseIK.tagSize - 1

    /// The plaintexts to encrypt, in order, for one frame.
    public static func split(_ frame: Data) -> [Data] {
        guard !frame.isEmpty else { return [Data([0])] }
        var out: [Data] = []
        var start = frame.startIndex
        while start < frame.endIndex {
            let end = frame.index(start, offsetBy: chunkSize, limitedBy: frame.endIndex) ?? frame.endIndex
            out.append(Data([end < frame.endIndex ? 1 : 0]) + frame[start..<end])
            start = end
        }
        return out
    }

    /// Joins decrypted messages back into frames. A frame over `limit` bytes is refused.
    public struct Joiner {
        private var buffer = Data()
        public let limit: Int

        public init(limit: Int = 32 << 20) { self.limit = limit }

        /// The finished frame when `plain` was the last chunk; nil when more follow. Throws on a bad header or size.
        public mutating func push(_ plain: Data) throws -> Data? {
            guard let more = plain.first, more <= 1 else { throw NoiseError.decryptFailed }
            guard buffer.count + plain.count - 1 <= limit else { throw NoiseError.tooLarge }
            buffer.append(plain.dropFirst())
            if more == 1 { return nil }
            defer { buffer = Data() }
            return buffer
        }
    }
}
