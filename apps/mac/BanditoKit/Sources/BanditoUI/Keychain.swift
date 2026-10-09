import Foundation
import Security

/// Device tokens live in the login Keychain, one item per server.
enum Keychain {
    private static let service = "dev.bandito.mac.server-token"

    static func token(for server: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored token. Returns whether the new token was stored (always true when clearing).
    @discardableResult
    static func setToken(_ token: String?, for server: UUID) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        guard let token else { return true }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        // Readable after the first unlock (background sync works), never copied to other devices.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
