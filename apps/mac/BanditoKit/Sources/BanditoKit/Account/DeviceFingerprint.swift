import CryptoKit
import Foundation

/// A short code that names a device by its X25519 public key. Both screens show it: the new device shows its
/// own code, the approving device asks the user to compare it with the code it was given. A server that swapped
/// the public key would produce a different code, so the mismatch is caught before any sync key is sealed.
/// See docs/ACCOUNTS_API.md#device-fingerprint.
public enum DeviceFingerprint {
    static let domain = "bandito-device-fp:v1"
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// The code of a raw X25519 public key (32 bytes): SHA-256 of the domain and the key, first 80 bits in
    /// base32 (RFC 4648 alphabet, no padding), grouped by four. Example: `K7QF-2MXA-7RTE-H4WB` (base32 uses A-Z and 2-7 only).
    public static func code(publicKey: Data) -> String {
        var input = Data(domain.utf8)
        input.append(publicKey)
        let digest = SHA256.hash(data: input)
        let symbols = base32(Array(digest.prefix(10)))
        let text = Array(String(decoding: symbols, as: UTF8.self))
        return stride(from: 0, to: text.count, by: 4)
            .map { String(text[$0..<min($0 + 4, text.count)]) }
            .joined(separator: "-")
    }

    /// The code of a base64 X25519 public key. Invalid base64, or a length other than 32 bytes, is
    /// `SyncKeyError.invalidPublicKey`.
    public static func code(publicKeyBase64: String) throws -> String {
        guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == 32 else {
            throw SyncKeyError.invalidPublicKey
        }
        return code(publicKey: raw)
    }

    /// Whether two codes are the same. Case, spaces and dashes do not matter. The comparison looks at every
    /// byte, so it does not stop early at the first difference. Codes of different length never match, and
    /// an empty code never matches.
    public static func matches(_ first: String, _ second: String) -> Bool {
        let left = normalized(first)
        let right = normalized(second)
        guard !left.isEmpty, left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    static func normalized(_ code: String) -> [UInt8] {
        Array(code.uppercased().filter { !$0.isWhitespace && $0 != "-" }.utf8)
    }

    /// RFC 4648 base32 without padding. Ten bytes give exactly sixteen symbols.
    static func base32(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = ((buffer << 8) | Int(byte)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(buffer >> bits) & 31])
            }
        }
        if bits > 0 {
            output.append(alphabet[(buffer << (5 - bits)) & 31])
        }
        return output
    }
}
