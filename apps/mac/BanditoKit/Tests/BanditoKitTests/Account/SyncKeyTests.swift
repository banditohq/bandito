import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct SyncKeyTests {
    @Test func envelopeOpensWithTheRecipientsKeyAndGivesTheSameKey() throws {
        let sender = SymmetricKey(size: .bits256)
        let recipient = try makeIdentity()

        let envelope = try SyncKey.seal(sender, forPublicKey: recipient.publicKeyBase64)
        let opened = try SyncKey.open(envelope: envelope, with: recipient)

        #expect(rawBytes(of: opened) == rawBytes(of: sender))
    }

    @Test func envelopeIsEncapsulatedKeyThenCiphertext() throws {
        let recipient = try makeIdentity()
        let envelope = try SyncKey.seal(SymmetricKey(size: .bits256), forPublicKey: recipient.publicKeyBase64)

        let bytes = try #require(Data(base64Encoded: envelope))
        // 32-byte X25519 encapsulated key, then 32 bytes of key plus a 16-byte tag.
        #expect(bytes.count == 32 + 32 + 16)
    }

    @Test func envelopeForAnotherDeviceCannotBeOpened() throws {
        let intended = try makeIdentity()
        let stranger = try makeIdentity()
        let envelope = try SyncKey.seal(SymmetricKey(size: .bits256), forPublicKey: intended.publicKeyBase64)

        #expect(throws: (any Error).self) {
            try SyncKey.open(envelope: envelope, with: stranger)
        }
    }

    @Test func sealRejectsAPublicKeyThatIsNotX25519Sized() {
        // "AAAA" decodes to three bytes: not an X25519 public key.
        #expect(throws: SyncKeyError.invalidPublicKey) {
            try SyncKey.seal(SymmetricKey(size: .bits256), forPublicKey: "AAAA")
        }
    }

    @Test func openRejectsMalformedEnvelopes() throws {
        let recipient = try makeIdentity()
        #expect(throws: SyncKeyError.malformedEnvelope) {
            try SyncKey.open(envelope: "not base64!", with: recipient)
        }
        #expect(throws: SyncKeyError.malformedEnvelope) {
            try SyncKey.open(envelope: Data([1, 2, 3]).base64EncodedString(), with: recipient)
        }
    }

    @Test func blobRoundTripsAndIsNotPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(#"{"version":1,"servers":[]}"#.utf8)

        let blob = try SyncKey.sealBlob(plaintext, key: key)

        #expect(!blob.contains("servers"))
        #expect(try SyncKey.openBlob(blob, key: key) == plaintext)
    }

    @Test func blobWithAnotherKeyOrTamperedBytesDoesNotOpen() throws {
        let key = SymmetricKey(size: .bits256)
        let blob = try SyncKey.sealBlob(Data("payload".utf8), key: key)

        #expect(throws: (any Error).self) {
            try SyncKey.openBlob(blob, key: SymmetricKey(size: .bits256))
        }

        var bytes = try #require(Data(base64Encoded: blob))
        bytes[bytes.count - 1] ^= 0x01
        #expect(throws: (any Error).self) {
            try SyncKey.openBlob(bytes.base64EncodedString(), key: key)
        }
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
