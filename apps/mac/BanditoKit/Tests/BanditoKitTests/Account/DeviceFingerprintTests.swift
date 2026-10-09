import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct DeviceFingerprintTests {
    /// Reference values computed independently: SHA-256("bandito-device-fp:v1" || key), first 10 bytes, base32.
    private let zeroToThirtyOne = Data(0..<32)
    private let allFF = Data(repeating: 0xFF, count: 32)

    @Test func codeMatchesTheReferenceVectors() {
        #expect(DeviceFingerprint.code(publicKey: zeroToThirtyOne) == "45IU-3YV7-MGPV-EGLY")
        #expect(DeviceFingerprint.code(publicKey: allFF) == "RPWE-7YAY-HTQS-JGUQ")
    }

    @Test func codeIsSixteenBase32SymbolsInGroupsOfFour() {
        let code = DeviceFingerprint.code(publicKey: zeroToThirtyOne)
        #expect(code.range(of: #"^[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}$"#, options: .regularExpression) != nil)
    }

    @Test func differentKeysGiveDifferentCodes() {
        #expect(DeviceFingerprint.code(publicKey: zeroToThirtyOne) != DeviceFingerprint.code(publicKey: allFF))
    }

    @Test func base64EntryPointGivesTheSameCode() throws {
        let code = try DeviceFingerprint.code(publicKeyBase64: zeroToThirtyOne.base64EncodedString())
        #expect(code == DeviceFingerprint.code(publicKey: zeroToThirtyOne))
    }

    @Test func invalidBase64OrWrongLengthIsAnInvalidPublicKey() {
        #expect(throws: SyncKeyError.invalidPublicKey) {
            try DeviceFingerprint.code(publicKeyBase64: "not base64!")
        }
        // Too short: 31 bytes.
        #expect(throws: SyncKeyError.invalidPublicKey) {
            try DeviceFingerprint.code(publicKeyBase64: Data(0..<31).base64EncodedString())
        }
        // Too long: 33 bytes.
        #expect(throws: SyncKeyError.invalidPublicKey) {
            try DeviceFingerprint.code(publicKeyBase64: Data(0..<33).base64EncodedString())
        }
        #expect(throws: SyncKeyError.invalidPublicKey) {
            try DeviceFingerprint.code(publicKeyBase64: "")
        }
    }

    @Test func codeWithSpacesAndInLowerCaseMatches() {
        let code = "45IU-3YV7-MGPV-EGLY"
        #expect(DeviceFingerprint.matches(code, "45iu 3yv7 mgpv egly"))
        #expect(DeviceFingerprint.matches(code, " 45IU3YV7MGPVEGLY "))
        #expect(DeviceFingerprint.matches(code, code))
    }

    @Test func aCodeOfAnotherLengthOrAnotherValueDoesNotMatch() {
        let code = "45IU-3YV7-MGPV-EGLY"
        #expect(!DeviceFingerprint.matches(code, "45IU-3YV7-MGPV-EGL"))
        #expect(!DeviceFingerprint.matches(code, "45IU-3YV7-MGPV-EGLYA"))
        #expect(!DeviceFingerprint.matches(code, "RPWE-7YAY-HTQS-JGUQ"))
        #expect(!DeviceFingerprint.matches(code, ""))
        #expect(!DeviceFingerprint.matches("", ""))
    }
}
