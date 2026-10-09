import CryptoKit
import Foundation

/// Checks a Bandito release on this Mac before anything is sent to a server. The release publishes `SHA256SUMS`
/// (`<sha256>  <file>` per line) and `SHA256SUMS.sig`: the raw Ed25519 signature of that file, base64. The check
/// passes only when the signature is valid for the release key, the archive is listed, and its SHA-256 matches.
/// The key is also `RELEASE_PUBKEY` in scripts/install.sh; a test keeps the two equal.
public enum ReleaseVerifier {
    public typealias PublicKey = Curve25519.Signing.PublicKey

    /// Why a release is refused. Each one stops the install before anything reaches the server.
    public enum Failure: Error, Equatable, Sendable {
        /// The signature is not valid for `SHA256SUMS` under the key: the file was changed, or another key signed it.
        case badSignature
        /// `SHA256SUMS` does not list the archive.
        case notListed
        /// The archive's SHA-256 is not the one `SHA256SUMS` lists.
        case checksumMismatch
        /// The signature or the checksum file cannot be read: bad base64, a signature of the wrong length, a line that
        /// is not `<hex>  <name>`, or a file listed twice.
        case malformed
    }

    /// The release signing key: raw Ed25519 public key, base64 (32 bytes).
    public static let releaseKeyBase64 = "0H7rMV2eLDmjqQ403ipWCERN6K+aZNuWTW5IKuLSpWY="

    public static let release: PublicKey = {
        // An invariant: the constant above is a 32-byte Ed25519 key, and ReleaseVerifierTests checks it against install.sh.
        guard let raw = Data(base64Encoded: releaseKeyBase64), let key = try? PublicKey(rawRepresentation: raw) else {
            fatalError("ReleaseVerifier.releaseKeyBase64 is not an Ed25519 public key")
        }
        return key
    }()

    /// Passes when `signatureBase64` is a valid signature of `sums` under `key`, `sums` lists `assetName` once, and the
    /// SHA-256 of `archive` is the hash it lists.
    public static func verify(
        sums: Data, signatureBase64: String, archive: Data, assetName: String, key: PublicKey = ReleaseVerifier.release
    ) throws {
        guard let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
            signature.count == 64
        else { throw Failure.malformed }
        // The signature comes first: nothing in an unsigned file is read.
        guard key.isValidSignature(signature, for: sums) else { throw Failure.badSignature }

        let matches = try entries(in: sums).filter { $0.name == assetName }
        guard let entry = matches.first else { throw Failure.notListed }
        guard matches.count == 1 else { throw Failure.malformed }
        guard entry.sha256 == sha256Hex(archive) else { throw Failure.checksumMismatch }
    }

    struct Entry: Equatable {
        var sha256: String
        var name: String
    }

    /// The lines of `sha256sum` output: `<hex>  <name>` (text mode) or `<hex> *<name>` (binary mode).
    static func entries(in sums: Data) throws -> [Entry] {
        guard let text = String(data: sums, encoding: .utf8) else { throw Failure.malformed }
        return try text.split(whereSeparator: \.isNewline).map { line in
            guard let space = line.firstIndex(of: " ") else { throw Failure.malformed }
            let hash = String(line[..<space])
            var name = line[line.index(after: space)...]
            if name.first == " " || name.first == "*" { name = name.dropFirst() }
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit), !name.isEmpty else { throw Failure.malformed }
            return Entry(sha256: hash.lowercased(), name: String(name))
        }
    }

    /// Lower-case hex SHA-256 of `data`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
