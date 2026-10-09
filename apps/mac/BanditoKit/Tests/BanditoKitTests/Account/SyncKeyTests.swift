import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct SyncKeyTests {
    private let accountID = "u1"

    private func envelopeBytes(_ envelope: String) throws -> [UInt8] {
        [UInt8](try #require(Data(base64Encoded: envelope)))
    }

    private func base64(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
    }

    @Test func envelopeOpensWithTheRecipientsKeyAndGivesTheSameKey() throws {
        let sender = try makeIdentity()
        let recipient = try makeIdentity()
        let original = SymmetricKey(size: .bits256)

        let envelope = try SyncKey.seal(original, forPublicKey: recipient.publicKeyBase64, sender: sender)
        let opened = try SyncKey.open(envelope: envelope, with: recipient)

        #expect(rawBytes(of: opened.key) == rawBytes(of: original))
        #expect(opened.senderFingerprint == sender.fingerprint)
    }

    @Test func envelopeIsVersionTwoSenderEncapsulatedKeyThenCiphertext() throws {
        let sender = try makeIdentity()
        let recipient = try makeIdentity()
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: recipient.publicKeyBase64, sender: sender)

        let bytes = try envelopeBytes(envelope)
        // 0x02, the sender's 32-byte X25519 public key, the 32-byte encapsulated key, 32 bytes of key plus a tag.
        #expect(bytes.count == 113)
        #expect(bytes[0] == 0x02)
        #expect(Data(bytes[1..<33]) == Data(base64Encoded: sender.publicKeyBase64))
    }

    @Test func envelopeForAnotherDeviceCannotBeOpened() throws {
        let sender = try makeIdentity()
        let intended = try makeIdentity()
        let stranger = try makeIdentity()
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: intended.publicKeyBase64, sender: sender)

        #expect(throws: SyncKeyError.cannotOpen) {
            try SyncKey.open(envelope: envelope, with: stranger)
        }
    }

    @Test func envelopeSealedByAnotherSenderReportsThatSenderFingerprint() throws {
        let firstSender = try makeIdentity()
        let secondSender = try makeIdentity()
        let recipient = try makeIdentity()

        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: recipient.publicKeyBase64, sender: secondSender)
        let opened = try SyncKey.open(envelope: envelope, with: recipient)

        #expect(opened.senderFingerprint == secondSender.fingerprint)
        #expect(opened.senderFingerprint != firstSender.fingerprint)
    }

    @Test func aSubstitutedSenderPublicKeyDoesNotOpen() throws {
        let sender = try makeIdentity()
        let impostor = try makeIdentity()
        let recipient = try makeIdentity()
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: recipient.publicKeyBase64, sender: sender)

        // Put another device's public key where the sender's key was: HPKE auth mode must reject it.
        var bytes = try envelopeBytes(envelope)
        let impostorKey = try #require(Data(base64Encoded: impostor.publicKeyBase64))
        bytes.replaceSubrange(1..<33, with: impostorKey)

        #expect(throws: SyncKeyError.cannotOpen) {
            try SyncKey.open(envelope: base64(bytes), with: recipient)
        }
    }

    @Test func sealRejectsAPublicKeyThatIsNotX25519Sized() throws {
        let sender = try makeIdentity()
        // "AAAA" decodes to three bytes: not an X25519 public key.
        #expect(throws: SyncKeyError.invalidPublicKey) {
            try SyncKey.seal(SymmetricKey(size: .bits256), forPublicKey: "AAAA", sender: sender)
        }
    }

    @Test func openRejectsMalformedEnvelopes() throws {
        let recipient = try makeIdentity()
        #expect(throws: SyncKeyError.invalidEnvelope) {
            try SyncKey.open(envelope: "not base64!", with: recipient)
        }
        #expect(throws: SyncKeyError.invalidEnvelope) {
            try SyncKey.open(envelope: Data([1, 2, 3]).base64EncodedString(), with: recipient)
        }
    }

    @Test func openRejectsEnvelopesOfAnotherLengthBeforeDecrypting() throws {
        let sender = try makeIdentity()
        let recipient = try makeIdentity()
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: recipient.publicKeyBase64, sender: sender)
        let bytes = try envelopeBytes(envelope)

        #expect(throws: SyncKeyError.invalidEnvelope) {
            try SyncKey.open(envelope: base64(Array(bytes.dropLast())), with: recipient)
        }
        #expect(throws: SyncKeyError.invalidEnvelope) {
            try SyncKey.open(envelope: base64(bytes + [0]), with: recipient)
        }
    }

    @Test func openRejectsTheVersionOneFormat() throws {
        let sender = try makeIdentity()
        let recipient = try makeIdentity()
        let envelope = try SyncKey.seal(
            SymmetricKey(size: .bits256), forPublicKey: recipient.publicKeyBase64, sender: sender)
        var bytes = try envelopeBytes(envelope)
        bytes[0] = 0x01

        #expect(throws: SyncKeyError.invalidEnvelope) {
            try SyncKey.open(envelope: base64(bytes), with: recipient)
        }
    }

    @Test func blobRoundTripsAndIsNotPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(#"{"version":1,"servers":[]}"#.utf8)
        let aad = SyncKey.blobAssociatedData(accountID: accountID, version: 3)

        let blob = try SyncKey.sealBlob(plaintext, key: key, associatedData: aad)

        #expect(!blob.contains("servers"))
        #expect(try SyncKey.openBlob(blob, key: key, associatedData: aad) == plaintext)
    }

    @Test func blobWithAnotherKeyOrTamperedBytesDoesNotOpen() throws {
        let key = SymmetricKey(size: .bits256)
        let aad = SyncKey.blobAssociatedData(accountID: accountID, version: 1)
        let blob = try SyncKey.sealBlob(Data("payload".utf8), key: key, associatedData: aad)

        #expect(throws: (any Error).self) {
            try SyncKey.openBlob(blob, key: SymmetricKey(size: .bits256), associatedData: aad)
        }

        var bytes = try #require(Data(base64Encoded: blob))
        bytes[bytes.count - 1] ^= 0x01
        #expect(throws: (any Error).self) {
            try SyncKey.openBlob(bytes.base64EncodedString(), key: key, associatedData: aad)
        }
    }

    @Test func blobBoundToAnotherAccountOrVersionDoesNotOpen() throws {
        let key = SymmetricKey(size: .bits256)
        let blob = try SyncKey.sealBlob(
            Data("payload".utf8), key: key,
            associatedData: SyncKey.blobAssociatedData(accountID: accountID, version: 4))

        #expect(throws: SyncKeyError.cannotOpen) {
            try SyncKey.openBlob(
                blob, key: key, associatedData: SyncKey.blobAssociatedData(accountID: "u2", version: 4))
        }
        // A server that relabels the blob with another version is caught the same way.
        #expect(throws: SyncKeyError.cannotOpen) {
            try SyncKey.openBlob(
                blob, key: key, associatedData: SyncKey.blobAssociatedData(accountID: accountID, version: 5))
        }
    }

    @Test func blobAssociatedDataIsTheDocumentedString() {
        #expect(
            SyncKey.blobAssociatedData(accountID: "acc-1", version: 7)
                == Data("bandito-sync-blob:v1:acc-1:7".utf8))
    }

    @Test func loadReturnsNilWhenNoKeyIsStored() throws {
        #expect(try SyncKey.load(from: MemorySecretStore()) == nil)
    }

    @Test func loadOrCreateCreatesOnceAndThenReturnsTheSameKey() throws {
        let store = MemorySecretStore()
        let created = try SyncKey.loadOrCreate(from: store)
        let again = try SyncKey.loadOrCreate(from: store)
        let loaded = try #require(try SyncKey.load(from: store))

        #expect(rawBytes(of: created).count == 32)
        #expect(rawBytes(of: again) == rawBytes(of: created))
        #expect(rawBytes(of: loaded) == rawBytes(of: created))
    }

    @Test func savedKeyIsStoredUnderTheSyncKeyAccount() throws {
        let store = MemorySecretStore()
        let key = SymmetricKey(size: .bits256)

        try SyncKey.save(key, to: store)

        #expect(SyncKey.keychainAccount == "sync-key")
        #expect(try store.load(account: "sync-key") == rawBytes(of: key))
    }
}
