import CryptoKit
import Foundation

@testable import BanditoKit

/// The daemon's side of the handshake, for tests only: a fake relay's daemon answers a phone with it.
struct NoiseResponder {
    private var symmetric: NoiseSymmetric
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private(set) var remoteStatic: Curve25519.KeyAgreement.PublicKey?

    init(
        staticKey: Curve25519.KeyAgreement.PrivateKey, prologue: Data = NoiseIK.prologue,
        ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil
    ) {
        self.staticKey = staticKey
        self.ephemeral = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        symmetric = NoiseSymmetric(protocolName: NoiseIK.protocolName, prologue: prologue)
        symmetric.mixHash(staticKey.publicKey.rawRepresentation)
    }

    /// `-> e, es, s, ss`. Returns the payload.
    mutating func readMessage1(_ message: Data) throws -> Data {
        guard message.count >= 32 + 48 + 16 else { throw NoiseError.handshakeFailed }
        let re = Data(message.prefix(32))
        let encryptedStatic = Data(message.dropFirst(32).prefix(48))
        let body = Data(message.dropFirst(80))
        let remoteE = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: re)
        symmetric.mixHash(re)
        symmetric.mixKey(try NoiseInitiator.dh(staticKey, remoteE))
        let s = try symmetric.decryptAndHash(encryptedStatic)
        let remoteS = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: s)
        symmetric.mixKey(try NoiseInitiator.dh(staticKey, remoteS))
        remoteEphemeral = remoteE
        remoteStatic = remoteS
        return try symmetric.decryptAndHash(body)
    }

    /// `<- e, ee, se`.
    mutating func writeMessage2(payload: Data) throws -> (message: Data, transport: NoiseTransport) {
        guard let remoteEphemeral, let remoteStatic else { throw NoiseError.handshakeFailed }
        let e = ephemeral.publicKey.rawRepresentation
        symmetric.mixHash(e)
        symmetric.mixKey(try NoiseInitiator.dh(ephemeral, remoteEphemeral))
        symmetric.mixKey(try NoiseInitiator.dh(ephemeral, remoteStatic))
        let body = try symmetric.encryptAndHash(payload)
        let (initiatorToResponder, responderToInitiator) = symmetric.split()
        return (
            e + body,
            NoiseTransport(send: SymmetricKey(data: responderToInitiator), receive: SymmetricKey(data: initiatorToResponder))
        )
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
