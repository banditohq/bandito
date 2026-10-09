import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct DeviceIdentityTests {
    @Test func loginSignatureVerifiesWithTheSigningKey() throws {
        let identity = try makeIdentity()
        let nonce = "abc_DEF-123"
        let signature = try #require(Data(base64Encoded: identity.sign(login: nonce)))
        let signingKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: try #require(Data(base64Encoded: identity.signingKeyBase64)))

        let message = DeviceIdentity.loginMessage(
            nonce: nonce, publicKey: identity.publicKeyBase64, signingKey: identity.signingKeyBase64)
        #expect(
            message
                == "bandito-login:v1:abc_DEF-123:\(identity.publicKeyBase64):\(identity.signingKeyBase64)")
        #expect(signingKey.isValidSignature(signature, for: Data(message.utf8)))

        // Another nonce is another message: the same signature must not verify.
        let other = DeviceIdentity.loginMessage(
            nonce: "other", publicKey: identity.publicKeyBase64, signingKey: identity.signingKeyBase64)
        #expect(!signingKey.isValidSignature(signature, for: Data(other.utf8)))
    }

    @Test func publicKeysAreRawKeysOf32Bytes() throws {
        let identity = try makeIdentity()
        #expect(try #require(Data(base64Encoded: identity.publicKeyBase64)).count == 32)
        #expect(try #require(Data(base64Encoded: identity.signingKeyBase64)).count == 32)
    }

    @Test func keysArePersistedAndReloadedUnchanged() throws {
        let store = MemorySecretStore()
        let first = try DeviceIdentity.load(from: store)
        let second = try DeviceIdentity.load(from: store)
        #expect(first.publicKeyBase64 == second.publicKeyBase64)
        #expect(first.signingKeyBase64 == second.signingKeyBase64)
        #expect(try store.load(account: "x25519") != nil)
        #expect(try store.load(account: "ed25519") != nil)
    }

    @Test func existingSigningKeyIsKeptNotRegenerated() throws {
        let store = MemorySecretStore()
        let existing = Curve25519.Signing.PrivateKey()
        try store.save(existing.rawRepresentation, account: "ed25519")

        let identity = try DeviceIdentity.load(from: store)
        #expect(identity.signingKeyBase64 == existing.publicKey.rawRepresentation.base64EncodedString())
    }

    @Test func keychainServiceIsTheDeviceService() {
        #expect(DeviceIdentity.keychainService == "dev.bandito.device")
    }
}
