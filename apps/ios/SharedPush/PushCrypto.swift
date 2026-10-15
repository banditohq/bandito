import CryptoKit
import Foundation

/// Opening a push (docs/ARCHITECTURE.md#push): ChaCha20-Poly1305, the 12-byte `nonce`, `ct` = ciphertext followed by the
/// 16-byte tag, and the associated data `bandito-push:v1:<handle>`.
enum PushCrypto {
    static let tagBytes = 16
    static let nonceBytes = 12

    static func associatedData(handle: String) -> Data {
        Data("bandito-push:v1:\(handle)".utf8)
    }

    /// The open text, or nil when `ct`/`nonce` are not what they should be, the key is another one, or the handle differs.
    static func open(ct: String, nonce: String, handle: String, key: SymmetricKey) -> Data? {
        guard let raw = Data(base64Encoded: ct), raw.count >= tagBytes,
            let nonceData = Data(base64Encoded: nonce), nonceData.count == nonceBytes,
            let sealedNonce = try? ChaChaPoly.Nonce(data: nonceData)
        else { return nil }
        guard let box = try? ChaChaPoly.SealedBox(
            nonce: sealedNonce, ciphertext: raw.dropLast(tagBytes), tag: raw.suffix(tagBytes))
        else { return nil }
        return try? ChaChaPoly.open(box, using: key, authenticating: associatedData(handle: handle))
    }

    /// Seals a text the way the daemon does. The phone never sends a push; this is for tests and the debug sender.
    static func seal(_ plain: Data, handle: String, key: SymmetricKey, nonce: Data? = nil) throws -> (ct: String, nonce: String) {
        let sealed = try ChaChaPoly.seal(
            plain, using: key, nonce: try nonce.map { try ChaChaPoly.Nonce(data: $0) } ?? ChaChaPoly.Nonce(),
            authenticating: associatedData(handle: handle))
        return ((sealed.ciphertext + sealed.tag).base64EncodedString(), Data(sealed.nonce).base64EncodedString())
    }

    /// The first key that opens the push, with its server. The keys are tried in order (a phone has one to three).
    static func open(
        userInfo: [AnyHashable: Any], handle: String, keys: [(serverRef: String, key: SymmetricKey)]
    ) -> (serverRef: String, plain: Data)? {
        guard let ct = userInfo["ct"] as? String, let nonce = userInfo["nonce"] as? String else { return nil }
        for candidate in keys {
            if let plain = open(ct: ct, nonce: nonce, handle: handle, key: candidate.key) {
                return (candidate.serverRef, plain)
            }
        }
        return nil
    }
}
