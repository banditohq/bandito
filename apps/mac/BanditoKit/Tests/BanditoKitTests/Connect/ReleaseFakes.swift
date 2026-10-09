import CryptoKit
import Foundation

@testable import BanditoKit

/// A release signed with a test key, the way the release job signs it: `SHA256SUMS` lists the archive, and the
/// signature is the raw Ed25519 signature of that file.
struct TestRelease {
    static let asset = "bandito-x86_64-unknown-linux-gnu.tar.gz"
    static let archive = Data("bandito archive bytes".utf8)

    let key = Curve25519.Signing.PrivateKey()

    var publicKey: Curve25519.Signing.PublicKey { key.publicKey }

    /// `SHA256SUMS` for `TestRelease.archive`.
    var sums: Data { Data("\(testSHA256Hex(Self.archive))  \(Self.asset)\n".utf8) }

    func signature(of data: Data) throws -> String {
        try key.signature(for: data).base64EncodedString()
    }

    /// The content of `SHA256SUMS.sig`.
    func signatureFile() throws -> String {
        try signature(of: sums)
    }
}

func testSHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A release source that serves fixed files and records every request. It writes the archive into the directory it
/// is asked for, as the GitHub source does.
final class FakeReleaseSource: ReleaseSource, @unchecked Sendable {
    // @unchecked: `recorded` is guarded by `lock`.
    struct Request: Equatable {
        var version: String?
        var asset: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private let archive: Data
    private let sums: Data
    private let signatureBase64: String
    private let fellBackToLatest: Bool
    private let failure: InstallError?

    init(
        archive: Data, sums: Data, signatureBase64: String, fellBackToLatest: Bool = false,
        failure: InstallError? = nil
    ) {
        self.archive = archive
        self.sums = sums
        self.signatureBase64 = signatureBase64
        self.fellBackToLatest = fellBackToLatest
        self.failure = failure
    }

    /// A source that serves `release` exactly as it was published.
    convenience init(_ release: TestRelease) {
        // Signing with a fresh Ed25519 key cannot fail.
        self.init(archive: TestRelease.archive, sums: release.sums, signatureBase64: try! release.signatureFile())
    }

    func fetch(version: String?, asset: String, into directory: URL) async throws -> FetchedRelease {
        lock.withLock { recorded.append(Request(version: version, asset: asset)) }
        if let failure { throw failure }
        let file = directory.appending(path: asset)
        try archive.write(to: file)
        return FetchedRelease(
            archive: file, sums: sums, signatureBase64: signatureBase64, fellBackToLatest: fellBackToLatest)
    }

    var requests: [Request] {
        lock.withLock { recorded }
    }
}

/// Records every file that scp was asked to copy, with its bytes read at the moment of the call.
final class CopyRecorder: @unchecked Sendable {
    // @unchecked: `copies` is guarded by `lock`.
    struct Copy {
        var path: String
        var data: Data?
    }

    private let lock = NSLock()
    private var copies: [Copy] = []

    func record(path: String) {
        let data = FileManager.default.contents(atPath: path)
        lock.withLock { copies.append(Copy(path: path, data: data)) }
    }

    var all: [Copy] {
        lock.withLock { copies }
    }
}
