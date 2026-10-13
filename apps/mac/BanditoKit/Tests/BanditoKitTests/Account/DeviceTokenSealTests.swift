import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct DeviceTokenSealTests {
    private let token = "bdt_" + String(repeating: "ab", count: 32)
    private let server = "00000000-0000-0000-0000-0000000000a1"

    private func seal(from sender: DeviceIdentity, to recipient: DeviceIdentity, account: String = "u1", device: String = "phone", server: String? = nil) throws -> String {
        try DeviceTokenSeal.seal(
            token: token, forPublicKey: recipient.publicKeyBase64, sender: sender, accountID: account,
            deviceID: device, serverID: server ?? self.server)
    }

    @Test func theRequestingDeviceOpensWhatAnotherDeviceSealed() throws {
        let mac = try makeIdentity()
        let phone = try makeIdentity()
        let sealed = try seal(from: mac, to: phone)
        let opened = try DeviceTokenSeal.open(
            sealed: sealed, with: phone, accountID: "u1", deviceID: "phone", serverID: server)
        #expect(opened.token == token)
        #expect(opened.senderPublicKey == mac.publicKeyBase64)
        // The token is not readable in the message.
        #expect(!(Data(base64Encoded: sealed) ?? Data()).contains(Data(token.utf8)))
        // The server id compares in lower case.
        #expect(try DeviceTokenSeal.open(sealed: sealed, with: phone, accountID: "u1", deviceID: "phone", serverID: server.uppercased()).token == token)
    }

    @Test func anotherDeviceAccountOrServerDoesNotOpenIt() throws {
        let mac = try makeIdentity()
        let phone = try makeIdentity()
        let stranger = try makeIdentity()
        let sealed = try seal(from: mac, to: phone)
        func opens(_ identity: DeviceIdentity, account: String = "u1", device: String = "phone", server: String? = nil) -> Bool {
            (try? DeviceTokenSeal.open(
                sealed: sealed, with: identity, accountID: account, deviceID: device, serverID: server ?? self.server)) != nil
        }
        #expect(opens(phone))
        #expect(!opens(stranger))
        #expect(!opens(phone, account: "u2"))
        #expect(!opens(phone, device: "tablet"))
        #expect(!opens(phone, server: "00000000-0000-0000-0000-0000000000a2"))
        // The sealing device cannot open its own message either: it is not the recipient.
        #expect(!opens(mac))
    }

    @Test func aChangedSenderOrChangedBytesDoNotOpen() throws {
        let mac = try makeIdentity()
        let phone = try makeIdentity()
        let evil = try makeIdentity()
        let sealed = try seal(from: mac, to: phone)
        var bytes = [UInt8](try #require(Data(base64Encoded: sealed)))
        // The sender's public key replaced by another device's: HPKE auth mode refuses it.
        let evilKey = [UInt8](try #require(Data(base64Encoded: evil.publicKeyBase64)))
        var swapped = bytes
        swapped.replaceSubrange(1..<33, with: evilKey)
        #expect(throws: DeviceTokenSealError.cannotOpen) {
            try DeviceTokenSeal.open(
                sealed: Data(swapped).base64EncodedString(), with: phone, accountID: "u1", deviceID: "phone", serverID: server)
        }
        // One flipped bit in the ciphertext.
        bytes[bytes.count - 1] ^= 1
        #expect(throws: DeviceTokenSealError.cannotOpen) {
            try DeviceTokenSeal.open(
                sealed: Data(bytes).base64EncodedString(), with: phone, accountID: "u1", deviceID: "phone", serverID: server)
        }
        // A message sealed by a device that is not the account's: refused when the caller knows the account's keys.
        let fromEvil = try seal(from: evil, to: phone)
        #expect(throws: DeviceTokenSealError.cannotOpen) {
            try DeviceTokenSeal.open(
                sealed: fromEvil, with: phone, accountID: "u1", deviceID: "phone", serverID: server,
                expectedSenders: [mac.publicKeyBase64])
        }
        #expect(
            try DeviceTokenSeal.open(
                sealed: sealed, with: phone, accountID: "u1", deviceID: "phone", serverID: server,
                expectedSenders: [mac.publicKeyBase64]
            ).token == token)
    }

    @Test func malformedInputIsRefusedBeforeAnyDecryption() throws {
        let phone = try makeIdentity()
        func open(_ text: String) throws {
            _ = try DeviceTokenSeal.open(sealed: text, with: phone, accountID: "u1", deviceID: "phone", serverID: server)
        }
        #expect(throws: DeviceTokenSealError.invalidSeal) { try open("not base64 !!") }
        #expect(throws: DeviceTokenSealError.invalidSeal) { try open(Data(repeating: 1, count: 40).base64EncodedString()) }
        #expect(throws: DeviceTokenSealError.invalidSeal) { try open(Data(repeating: 9, count: 120).base64EncodedString()) }
        #expect(throws: DeviceTokenSealError.invalidSeal) { try open(Data(repeating: 1, count: 100_000).base64EncodedString()) }
        let mac = try makeIdentity()
        #expect(throws: DeviceTokenSealError.invalidPublicKey) {
            try DeviceTokenSeal.seal(token: "t", forPublicKey: "AAAA", sender: mac, accountID: "u", deviceID: "d", serverID: server)
        }
        #expect(throws: DeviceTokenSealError.invalidToken) {
            try DeviceTokenSeal.seal(token: "", forPublicKey: phone.publicKeyBase64, sender: mac, accountID: "u", deviceID: "d", serverID: server)
        }
    }
}
