import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

@Suite struct ReleaseVerifierTests {
    private let release = TestRelease()
    private let asset = TestRelease.asset
    private let archive = TestRelease.archive

    private func check(
        sums: Data, signatureBase64: String, archive: Data? = nil, asset: String? = nil,
        key: Curve25519.Signing.PublicKey? = nil
    ) throws {
        try ReleaseVerifier.verify(
            sums: sums, signatureBase64: signatureBase64, archive: archive ?? self.archive,
            assetName: asset ?? self.asset, key: key ?? release.publicKey)
    }

    @Test func aValidSignatureAndAMatchingHashPass() throws {
        try check(sums: release.sums, signatureBase64: release.signatureFile)
    }

    @Test func binaryModeLinesAreReadToo() throws {
        let sums = Data("\(testSHA256Hex(archive)) *\(asset)\n".utf8)
        try check(sums: sums, signatureBase64: try release.signature(of: sums))
    }

    @Test func aTrailingNewlineAroundTheSignatureIsIgnored() throws {
        try check(sums: release.sums, signatureBase64: release.signatureFile + "\n")
    }

    @Test func changedSumsFailTheSignature() throws {
        let signature = release.signatureFile
        let changed = Data("\(testSHA256Hex(Data("evil".utf8)))  \(asset)\n".utf8)
        #expect(throws: ReleaseVerifier.Failure.badSignature) {
            try check(sums: changed, signatureBase64: signature)
        }
    }

    @Test func aSignatureFromAnotherKeyFails() throws {
        let foreign = Curve25519.Signing.PrivateKey()
        let signature = try foreign.signature(for: release.sums).base64EncodedString()
        #expect(throws: ReleaseVerifier.Failure.badSignature) {
            try check(sums: release.sums, signatureBase64: signature)
        }
    }

    @Test func aTestSignatureDoesNotPassTheReleaseKey() throws {
        // The production key never accepts a signature made with another key.
        #expect(throws: ReleaseVerifier.Failure.badSignature) {
            try check(sums: release.sums, signatureBase64: release.signatureFile, key: ReleaseVerifier.release)
        }
    }

    @Test func anArchiveThatSumsDoesNotListIsRefused() throws {
        let sums = Data("\(testSHA256Hex(archive))  bandito-aarch64-apple-darwin.tar.gz\n".utf8)
        #expect(throws: ReleaseVerifier.Failure.notListed) {
            try check(sums: sums, signatureBase64: try release.signature(of: sums))
        }
    }

    @Test func anArchiveWithAnotherHashIsRefused() throws {
        let sums = Data("\(testSHA256Hex(Data("other".utf8)))  \(asset)\n".utf8)
        #expect(throws: ReleaseVerifier.Failure.checksumMismatch) {
            try check(sums: sums, signatureBase64: try release.signature(of: sums))
        }
    }

    @Test func aTamperedArchiveIsRefused() throws {
        #expect(throws: ReleaseVerifier.Failure.checksumMismatch) {
            try check(sums: release.sums, signatureBase64: release.signatureFile, archive: Data("x".utf8))
        }
    }

    @Test func garbageInTheSignatureFileIsMalformed() throws {
        #expect(throws: ReleaseVerifier.Failure.malformed) {
            try check(sums: release.sums, signatureBase64: "%%% not base64 %%%")
        }
    }

    @Test func aSignatureOfTheWrongLengthIsMalformed() throws {
        let short = Data(repeating: 7, count: 10).base64EncodedString()
        #expect(throws: ReleaseVerifier.Failure.malformed) {
            try check(sums: release.sums, signatureBase64: short)
        }
    }

    @Test func aLineWithANonHexHashIsMalformed() throws {
        let sums = Data("\(String(repeating: "z", count: 64))  \(asset)\n".utf8)
        #expect(throws: ReleaseVerifier.Failure.malformed) {
            try check(sums: sums, signatureBase64: try release.signature(of: sums))
        }
    }

    @Test func aFileListedTwiceIsMalformed() throws {
        let line = "\(testSHA256Hex(archive))  \(asset)\n"
        let sums = Data((line + line).utf8)
        #expect(throws: ReleaseVerifier.Failure.malformed) {
            try check(sums: sums, signatureBase64: try release.signature(of: sums))
        }
    }

    @Test func theFailuresHaveTheTextTheInstallShows() {
        let error = InstallError.releaseCheckFailed(.badSignature)
        #expect(
            error.errorDescription
                == "Release signature check failed — the download may have been tampered with. Nothing was installed.")
    }

    @Test func theReleaseKeyIsTheRawKeyThatInstallShScriptCarries() throws {
        // #filePath: .../apps/mac/BanditoKit/Tests/BanditoKitTests/Connect/<this file>. Seven steps up is the repo root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let script = try String(contentsOf: root.appending(path: "scripts/install.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("RELEASE_PUBKEY=") })
        let encoded = line.dropFirst("RELEASE_PUBKEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let spki = try #require(Data(base64Encoded: String(encoded)))

        // SubjectPublicKeyInfo of an Ed25519 key: a 12-byte header, then the 32 raw bytes.
        let header = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
        #expect(spki.count == 44)
        #expect(spki.prefix(12) == header)
        #expect(ReleaseVerifier.release.rawRepresentation == spki.suffix(32))
        #expect(ReleaseVerifier.releaseKeyBase64 == spki.suffix(32).base64EncodedString())
    }
}
