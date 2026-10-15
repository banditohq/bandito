import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct JoinTicketTests {
    /// The secret of the fixed vectors: bytes 0x00 ... 0x1f.
    private let fixedSecret = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))

    private func fixedTicket(name: String = "Ann's Mac") -> JoinTicket {
        JoinTicket(secret: fixedSecret, macKeyHash: Data(repeating: 7, count: 32), macName: name)
    }

    private func hex(_ data: Data) -> String {
        data.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    private func madeTicket(name: String = "Ann's MacBook") -> JoinTicket {
        JoinTicket.make(macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey, macName: name)
    }

    /// A join link text with the given parts. `t` and `m` default to 32 bytes of base64url.
    private func linkText(
        scheme: String = "bandito", host: String = "join", version: String = "1",
        secret: String = Base64URL.encode(Data(repeating: 1, count: 32)),
        hash: String = Base64URL.encode(Data(repeating: 2, count: 32)), extra: String = ""
    ) -> String {
        "\(scheme)://\(host)?v=\(version)&t=\(secret)&m=\(hash)\(extra)"
    }

    // MARK: link and parse

    @Test func linkParsesBackToTheSameSecretHashAndName() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey().publicKey
        let ticket = JoinTicket.make(macPublicKey: mac, macName: "Ann's MacBook")

        let parsed = try #require(JoinTicket.parse(ticket.link))

        #expect(rawBytes(of: parsed.secret) == rawBytes(of: ticket.secret))
        #expect(parsed.macKeyHash == ticket.macKeyHash)
        #expect(parsed.macKeyHash == Data(SHA256.hash(data: mac.rawRepresentation)))
        #expect(parsed.macName == "Ann's MacBook")
        #expect(parsed.ticketHash == ticket.ticketHash)
        #expect(JoinTicket.parse(ticket.link.absoluteString) != nil)
    }

    @Test func linkHasTheDocumentedShape() {
        let link = fixedTicket(name: "Mac").link.absoluteString
        // The secret is bytes 0x00 ... 0x1f in base64url (the standard base64 minus its padding).
        let secretText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        let hashText = Base64URL.encode(Data(repeating: 7, count: 32))

        #expect(link == "bandito://join?v=1&t=\(secretText)&m=\(hashText)&n=Mac")
    }

    @Test func aTicketWithoutANameHasNoNameParameterAndParsesWithoutOne() throws {
        let ticket = madeTicket(name: "")

        #expect(!ticket.link.absoluteString.contains("&n="))
        #expect(try #require(JoinTicket.parse(ticket.link)).macName == "")
    }

    @Test func aLongNameIsCutToFortyCharacters() throws {
        let ticket = madeTicket(name: String(repeating: "я", count: 60))
        #expect(ticket.macName.count == 40)

        let parsed = try #require(JoinTicket.parse(ticket.link))
        #expect(parsed.macName == String(repeating: "я", count: 40))

        // Emoji count as one character each.
        let emoji = madeTicket(name: String(repeating: "🙂", count: 45))
        #expect(emoji.macName.count == 40)
        #expect(try #require(JoinTicket.parse(emoji.link)).macName == String(repeating: "🙂", count: 40))
    }

    @Test func aNameWithEmojiAmpersandAndSeparatorsRoundTrips() throws {
        let name = "Ann 🖥 & Co = a+b/c?d#e %20"
        let ticket = madeTicket(name: name)

        let parsed = try #require(JoinTicket.parse(ticket.link))

        #expect(parsed.macName == name)
        #expect(JoinTicket.parse(ticket.link.absoluteString)?.macName == name)
    }

    @Test func standardBase64WithPaddingIsAcceptedForSecretAndHash() throws {
        // 0xFB bytes give "+" and "/" in the standard alphabet; the 32-byte secret gives "=" padding.
        let secretText = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        let hashText = Data(repeating: 0xFB, count: 32).base64EncodedString()
        #expect(secretText.hasSuffix("="))
        #expect(hashText.contains("+") && hashText.contains("/"))
        let text = "bandito://join?v=1&t=\(secretText.escaped)&m=\(hashText.escaped)&n=Mac"

        let parsed = try #require(JoinTicket.parse(text))

        #expect(rawBytes(of: parsed.secret) == Data((0..<32).map { UInt8($0) }))
        #expect(parsed.macKeyHash == Data(repeating: 0xFB, count: 32))
        #expect(parsed.authToken == fixedTicket().authToken)
    }

    @Test func malformedLinksParseToNil() {
        let good = linkText()
        #expect(JoinTicket.parse(good) != nil)
        let tOnly = Base64URL.encode(Data(repeating: 1, count: 32))
        let mOnly = Base64URL.encode(Data(repeating: 2, count: 32))

        let refused: [String] = [
            linkText(scheme: "https"),
            linkText(host: "pair"),
            linkText(version: "2"),
            linkText(version: ""),
            linkText(secret: Base64URL.encode(Data(repeating: 1, count: 20))),
            linkText(hash: Base64URL.encode(Data(repeating: 2, count: 33))),
            linkText(secret: "!!!not-base64!!!"),
            linkText(extra: "&extra=1"),
            linkText(extra: "&n=a&n=b"),
            "bandito://join?t=\(tOnly)&m=\(mOnly)",
            "bandito://join/extra?v=1&t=\(tOnly)&m=\(mOnly)",
            good + "#fragment",
            "bandito://user@join?v=1&t=\(tOnly)&m=\(mOnly)",
            "bandito:join?v=1",
            "not a link",
            ""
        ]
        for text in refused {
            #expect(JoinTicket.parse(text) == nil, "accepted \(text)")
        }
    }

    @Test func parseFromAURLRefusesTheSameThings() throws {
        let url = try #require(URL(string: linkText(version: "2")))
        #expect(JoinTicket.parse(url) == nil)
        #expect(JoinTicket.parse(try #require(URL(string: linkText()))) != nil)
    }

    // MARK: keys and vectors

    @Test func authKeyAndMacKeyAreDifferentKeys() {
        let ticket = madeTicket()

        #expect(ticket.authKey.count == 32)
        #expect(rawBytes(of: ticket.macKey).count == 32)
        #expect(ticket.authKey != rawBytes(of: ticket.macKey))
    }

    @Test func fixedSecretGivesFixedHashAndTokenAndMatchesCryptoKitHKDF() throws {
        let ticket = fixedTicket()

        // Values computed once, with an HKDF-SHA256 written outside Swift (RFC 5869, zero salt).
        #expect(ticket.ticketHash == "b08c189747a90dce1eff6a713a7bc0c9749ea603e7419dda8c562fae7a74688c")
        #expect(ticket.authToken == "FS6iLpSDzp9GYZp7KylMbuLO0MNB4CASYzk28nGCgDw")
        #expect(hex(ticket.authKey) == "152ea22e9483ce9f46619a7b2b294c6ee2ced0c341e02012633936f27182803c")
        #expect(hex(rawBytes(of: ticket.macKey)) == "4cf2c2c89bb2207b2b6196d47ec923760e88133834f5fd3f15cc28f4d6f09575")

        // The same values through CryptoKit's HKDF called directly.
        let authKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: fixedSecret, info: Data("bandito-join:auth:v1".utf8), outputByteCount: 32)
        let macKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: fixedSecret, info: Data("bandito-join:mac:v1".utf8), outputByteCount: 32)
        #expect(ticket.authKey == rawBytes(of: authKey))
        #expect(rawBytes(of: ticket.macKey) == rawBytes(of: macKey))
        #expect(ticket.ticketHash == hex(Data(SHA256.hash(data: rawBytes(of: authKey)))))
        #expect(try #require(Base64URL.decode(ticket.authToken)) == rawBytes(of: authKey))
    }

    // MARK: proof

    private let macKey = SymmetricKey(data: Data(repeating: 0x11, count: 32))
    private let publicKey = "AQIDBA=="
    private let signingKey = "BQYHCA=="

    @Test func proofVerifiesForItsOwnKeys() {
        let proof = JoinProof.make(macKey: macKey, publicKey: publicKey, signingKey: signingKey)

        // Value computed once, with HMAC-SHA256 written outside Swift.
        #expect(proof == "l9SFdUCLke63YIUn8CEc2p1OT5rDYhSJ5w7DZ0sRvLk")
        #expect(JoinProof.verify(proof, macKey: macKey, publicKey: publicKey, signingKey: signingKey))
    }

    @Test func proofFailsForAnyOtherKeyOrAForgedText() {
        let proof = JoinProof.make(macKey: macKey, publicKey: publicKey, signingKey: signingKey)
        var forged = Array(proof)
        forged[0] = forged[0] == "A" ? "B" : "A"

        #expect(!JoinProof.verify(proof, macKey: macKey, publicKey: "AQIDBB==", signingKey: signingKey))
        #expect(!JoinProof.verify(proof, macKey: macKey, publicKey: publicKey, signingKey: "BQYHCB=="))
        #expect(!JoinProof.verify(
            proof, macKey: SymmetricKey(data: Data(repeating: 0x12, count: 32)),
            publicKey: publicKey, signingKey: signingKey))
        #expect(!JoinProof.verify(String(forged), macKey: macKey, publicKey: publicKey, signingKey: signingKey))
        #expect(!JoinProof.verify("!!! not base64 !!!", macKey: macKey, publicKey: publicKey, signingKey: signingKey))
        #expect(!JoinProof.verify("", macKey: macKey, publicKey: publicKey, signingKey: signingKey))
    }

    @Test func aProofIsNotAcceptedAcrossTheTwoFields() {
        // The message names both fields, so swapping them is not the same proof.
        let proof = JoinProof.make(macKey: macKey, publicKey: publicKey, signingKey: signingKey)
        #expect(!JoinProof.verify(proof, macKey: macKey, publicKey: signingKey, signingKey: publicKey))
    }

    // MARK: sender of the envelope

    @Test func anEnvelopeSealedByThisMacIsFromThisMac() throws {
        let mac = try makeIdentity()
        let phone = try makeIdentity()
        let ticket = JoinTicket.make(macPublicKey: mac.agreementKey.publicKey, macName: "Mac")
        let envelope = try envelopeData(from: mac, to: phone)

        #expect(ticket.isFromMac(envelope: envelope))
        #expect(SyncKey.senderPublicKey(ofEnvelope: envelope) == mac.agreementKey.publicKey.rawRepresentation)
    }

    @Test func anEnvelopeFromAnotherSenderIsNotFromThisMac() throws {
        let mac = try makeIdentity()
        let other = try makeIdentity()
        let phone = try makeIdentity()
        let ticket = JoinTicket.make(macPublicKey: mac.agreementKey.publicKey, macName: "Mac")

        #expect(!ticket.isFromMac(envelope: try envelopeData(from: other, to: phone)))
    }

    @Test func aMalformedEnvelopeHasNoSenderAndIsNotFromThisMac() throws {
        let mac = try makeIdentity()
        let phone = try makeIdentity()
        let ticket = JoinTicket.make(macPublicKey: mac.agreementKey.publicKey, macName: "Mac")
        var wrongVersion = try envelopeData(from: mac, to: phone)
        wrongVersion[wrongVersion.startIndex] = 0x01

        #expect(SyncKey.senderPublicKey(ofEnvelope: wrongVersion) == nil)
        #expect(!ticket.isFromMac(envelope: wrongVersion))
        #expect(SyncKey.senderPublicKey(ofEnvelope: Data(repeating: 0x02, count: 40)) == nil)
        #expect(!ticket.isFromMac(envelope: Data()))
    }

    private func envelopeData(from sender: DeviceIdentity, to recipient: DeviceIdentity) throws -> Data {
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: recipient.publicKeyBase64, sender: sender,
            accountID: "u1", deviceID: "d2")
        return try #require(Data(base64Encoded: envelope))
    }

    // MARK: description

    @Test func aJoinLinkInsideAMessageIsFound() throws {
        let ticket = madeTicket(name: "Studio 🦝")
        let found = try #require(JoinTicket.find(in: "Sign in here:\n\(ticket.link.absoluteString)\nthanks"))
        #expect(found.ticketHash == ticket.ticketHash)
        #expect(found.macName == "Studio 🦝")
        #expect(JoinTicket.find(in: "BANDITO://JOIN?v=1") == nil)
        #expect(JoinTicket.find(in: "bandito://pair?v=1&code=x") == nil)
        #expect(JoinTicket.find(in: "no link at all") == nil)
        #expect(JoinTicket.find(in: "") == nil)
    }

    @Test func theSecretIsNotPrintedInAnyDescription() {
        let ticket = fixedTicket()
        let text = "\(ticket) \(String(reflecting: ticket))"

        #expect(text.contains("Ann's Mac"))
        #expect(!text.contains(Base64URL.encode(rawBytes(of: ticket.secret))))
        #expect(!text.contains(ticket.authToken))
        #expect(!text.contains(ticket.ticketHash))
        #expect(!text.contains(ticket.macKey.withUnsafeBytes { Data($0) }.base64EncodedString()))
    }
}

private extension String {
    /// The text with the characters of the standard base64 alphabet that a query value must escape.
    var escaped: String {
        replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "=", with: "%3D")
    }
}
