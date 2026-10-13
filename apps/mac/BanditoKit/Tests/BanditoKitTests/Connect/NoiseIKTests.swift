import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

/// The handshake and the transport against the vectors `snow` (the daemon's library) made: the same keys must give the
/// same bytes, and the daemon's bytes must open here. The file is `daemon/tests/fixtures/noise_ik_vectors.json`.
@Suite struct NoiseVectorTests {
    struct Sealed: Decodable {
        var plain: String
        var cipher: String
    }

    struct Vectors: Decodable {
        var pattern: String
        var prologue: String
        var initiatorStaticPrivate: String
        var initiatorStaticPublic: String
        var responderStaticPrivate: String
        var responderStaticPublic: String
        var initiatorEphemeralPrivate: String
        var responderEphemeralPrivate: String
        var message1Payload: String
        var message1: String
        var message2Payload: String
        var message2: String
        var initiatorToResponder: [Sealed]
        var responderToInitiator: [Sealed]
    }

    static func load() throws -> Vectors {
        // …/apps/mac/BanditoKit/Tests/BanditoKitTests/Connect/NoiseIKTests.swift → the repository root is 7 levels up.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let file = url.appending(path: "daemon/tests/fixtures/noise_ik_vectors.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Vectors.self, from: Data(contentsOf: file))
    }

    func key(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try #require(Data(hex: hex)))
    }

    @Test func theProtocolIsTheOneTheDaemonRuns() throws {
        let v = try Self.load()
        #expect(v.pattern == NoiseIK.protocolName)
        #expect(v.prologue == NoiseIK.prologue.hex)
    }

    @Test func theInitiatorMakesTheDaemonsBytesAndOpensItsAnswer() throws {
        let v = try Self.load()
        let staticKey = try key(v.initiatorStaticPrivate)
        #expect(staticKey.publicKey.rawRepresentation.hex == v.initiatorStaticPublic)
        var initiator = try NoiseInitiator(
            staticKey: staticKey, remoteStatic: try #require(Data(hex: v.responderStaticPublic)),
            ephemeral: try key(v.initiatorEphemeralPrivate))
        let message1 = try initiator.writeMessage1(payload: try #require(Data(hex: v.message1Payload)))
        #expect(message1.hex == v.message1)

        let (payload, transport) = try initiator.readMessage2(try #require(Data(hex: v.message2)))
        #expect(payload.hex == v.message2Payload)
        var session = transport
        for item in v.initiatorToResponder {
            #expect(try session.encrypt(try #require(Data(hex: item.plain))).hex == item.cipher)
        }
        for item in v.responderToInitiator {
            #expect(try session.decrypt(try #require(Data(hex: item.cipher))).hex == item.plain)
        }
    }

    @Test func theSwiftResponderMakesTheSameAnswerAsSnow() throws {
        let v = try Self.load()
        var responder = NoiseResponder(
            staticKey: try key(v.responderStaticPrivate), ephemeral: try key(v.responderEphemeralPrivate))
        let payload = try responder.readMessage1(try #require(Data(hex: v.message1)))
        #expect(payload.hex == v.message1Payload)
        #expect(responder.remoteStatic?.rawRepresentation.hex == v.initiatorStaticPublic)
        let (message2, transport) = try responder.writeMessage2(payload: try #require(Data(hex: v.message2Payload)))
        #expect(message2.hex == v.message2)
        var session = transport
        for item in v.initiatorToResponder {
            #expect(try session.decrypt(try #require(Data(hex: item.cipher))).hex == item.plain)
        }
    }

    @Test func aWrongDaemonKeyOrATamperedAnswerFails() throws {
        let v = try Self.load()
        let wrong = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        var initiator = try NoiseInitiator(
            staticKey: try key(v.initiatorStaticPrivate), remoteStatic: wrong, ephemeral: try key(v.initiatorEphemeralPrivate))
        _ = try initiator.writeMessage1(payload: Data("{}".utf8))
        #expect(throws: NoiseError.self) { try initiator.readMessage2(try #require(Data(hex: v.message2))) }

        var again = try NoiseInitiator(
            staticKey: try key(v.initiatorStaticPrivate), remoteStatic: try #require(Data(hex: v.responderStaticPublic)),
            ephemeral: try key(v.initiatorEphemeralPrivate))
        _ = try again.writeMessage1(payload: try #require(Data(hex: v.message1Payload)))
        var bytes = try #require(Data(hex: v.message2))
        bytes[bytes.count - 1] ^= 1
        #expect(throws: NoiseError.self) { try again.readMessage2(bytes) }
    }

    @Test func aReplayedOrReorderedMessageFails() throws {
        let v = try Self.load()
        var initiator = try NoiseInitiator(
            staticKey: try key(v.initiatorStaticPrivate), remoteStatic: try #require(Data(hex: v.responderStaticPublic)),
            ephemeral: try key(v.initiatorEphemeralPrivate))
        _ = try initiator.writeMessage1(payload: try #require(Data(hex: v.message1Payload)))
        var (_, session) = try initiator.readMessage2(try #require(Data(hex: v.message2)))
        let first = try #require(Data(hex: v.responderToInitiator[0].cipher))
        _ = try session.decrypt(first)
        #expect(throws: NoiseError.self) { try session.decrypt(first) }
        #expect(throws: NoiseError.self) { try session.decrypt(Data(count: 3)) }
    }

    @Test func badKeysAreRefused() {
        #expect(throws: NoiseError.badKey) {
            _ = try NoiseInitiator(staticKey: Curve25519.KeyAgreement.PrivateKey(), remoteStatic: Data(count: 31))
        }
    }

    @Test func largeFramesAreCutAtTheLimitAndJoinBack() throws {
        for size in [0, 1, NoiseFraming.chunkSize - 1, NoiseFraming.chunkSize, NoiseFraming.chunkSize + 1, 200_000] {
            let frame = Data((0..<size).map { UInt8($0 % 251) })
            let parts = NoiseFraming.split(frame)
            #expect(parts.allSatisfy { $0.count + NoiseIK.tagSize <= NoiseIK.maxMessage })
            #expect(parts.dropLast().allSatisfy { $0.first == 1 } && parts.last?.first == 0)
            var joiner = NoiseFraming.Joiner()
            var result: Data?
            for part in parts { result = try joiner.push(part) }
            #expect(result == frame)
        }
        var joiner = NoiseFraming.Joiner(limit: 4)
        #expect(throws: NoiseError.self) { try joiner.push(Data([0, 1, 2, 3, 4, 5])) }
        var bad = NoiseFraming.Joiner()
        #expect(throws: NoiseError.self) { try bad.push(Data([2, 1])) }
        #expect(throws: NoiseError.self) { try bad.push(Data()) }
    }

    @Test func aLowOrderPointNeverGivesAKey() throws {
        let v = try Self.load()
        let low: [Data] = [
            Data(count: 32),
            Data([1] + [UInt8](repeating: 0, count: 31)),
            try #require(Data(hex: "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")),
            try #require(Data(hex: "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157")),
        ]
        for point in low {
            // A daemon key that is a low-order point: the first message cannot be written.
            var initiator = try NoiseInitiator(staticKey: try key(v.initiatorStaticPrivate), remoteStatic: point)
            #expect(throws: NoiseError.handshakeFailed) { _ = try initiator.writeMessage1(payload: Data("{}".utf8)) }
            // An answer whose ephemeral key is a low-order point is refused, whatever follows.
            var again = try NoiseInitiator(
                staticKey: try key(v.initiatorStaticPrivate), remoteStatic: try #require(Data(hex: v.responderStaticPublic)),
                ephemeral: try key(v.initiatorEphemeralPrivate))
            _ = try again.writeMessage1(payload: try #require(Data(hex: v.message1Payload)))
            #expect(throws: NoiseError.handshakeFailed) { _ = try again.readMessage2(point + Data(count: 32)) }
        }
    }
}
