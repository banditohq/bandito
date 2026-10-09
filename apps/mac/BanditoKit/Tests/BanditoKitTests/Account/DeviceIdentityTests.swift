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

    @Test func fingerprintIsTheCodeOfThePublicKey() throws {
        let identity = try makeIdentity()
        let raw = try #require(Data(base64Encoded: identity.publicKeyBase64))
        #expect(identity.fingerprint == DeviceFingerprint.code(publicKey: raw))
    }

    @Test func keysArePersistedAndReloadedUnchanged() async throws {
        let store = MemorySecretStore()
        let first = try await DeviceIdentityStore(secrets: store).load()
        let second = try await DeviceIdentityStore(secrets: store).load()
        #expect(first.publicKeyBase64 == second.publicKeyBase64)
        #expect(first.signingKeyBase64 == second.signingKeyBase64)
        #expect(try store.load(account: "x25519") != nil)
        #expect(try store.load(account: "ed25519") != nil)
    }

    @Test func existingSigningKeyIsKeptNotRegenerated() async throws {
        let store = MemorySecretStore()
        let existing = Curve25519.Signing.PrivateKey()
        try store.save(existing.rawRepresentation, account: "ed25519")

        let identity = try await DeviceIdentityStore(secrets: store).load()
        #expect(identity.signingKeyBase64 == existing.publicKey.rawRepresentation.base64EncodedString())
    }

    @Test func twentyConcurrentLoadsGiveOneKeyPair() async throws {
        let store = DeviceIdentityStore(secrets: MemorySecretStore())
        let keys = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.load().publicKeyBase64 }
            }
            var collected: [String] = []
            for try await key in group {
                collected.append(key)
            }
            return collected
        }

        #expect(keys.count == 20)
        #expect(Set(keys).count == 1)
    }

    @Test func aDamagedStoredKeyIsCorruptKeyAndNothingIsReplaced() async throws {
        let store = MemorySecretStore()
        try store.save(Data([1, 2, 3]), account: "x25519")

        await #expect(throws: DeviceIdentityError.corruptKey) {
            try await DeviceIdentityStore(secrets: store).load()
        }
        #expect(try store.load(account: "x25519") == Data([1, 2, 3]))
    }

    @Test func aDamagedSigningKeyIsCorruptKey() async throws {
        let store = MemorySecretStore()
        try store.save(Data(repeating: 7, count: 5), account: "ed25519")

        await #expect(throws: DeviceIdentityError.corruptKey) {
            try await DeviceIdentityStore(secrets: store).load()
        }
    }

    @Test func resetRemovesBothKeysAndTheNextLoadMakesNewOnes() async throws {
        let store = MemorySecretStore()
        let identities = DeviceIdentityStore(secrets: store)
        let before = try await identities.load()

        try await identities.reset()

        #expect(try store.load(account: "x25519") == nil)
        #expect(try store.load(account: "ed25519") == nil)
        let after = try await identities.load()
        #expect(after.publicKeyBase64 != before.publicKeyBase64)
    }

    @Test func keychainServiceIsTheDeviceService() {
        #expect(DeviceIdentity.keychainService == "dev.bandito.device")
    }
}
