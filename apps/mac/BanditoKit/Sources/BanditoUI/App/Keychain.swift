import BanditoKit
import Foundation
import Security

/// Device tokens live in the login Keychain, one item per server.
enum Keychain {
    private static let service = KeychainNamespace.scoped("dev.bandito.mac.server-token")

    static func token(for server: UUID) -> String? { string(account: server.uuidString) }

    /// The relay key (base64url) of a server reached through Bandito Relay, next to its token.
    static func noiseSecret(for server: UUID) -> String? { string(account: server.uuidString + ".noise") }

    @discardableResult
    static func setNoiseSecret(_ secret: String?, for server: UUID) -> Bool { setString(secret, account: server.uuidString + ".noise") }

    private static func string(account: String) -> String? {
        if let file = KeychainNamespace.debugFileStore(service: service) {
            return (try? file.load(account: account)).flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored token in place (`SecItemUpdate`), or adds it when there is none. Clearing deletes it.
    /// Returns whether the change was made (clearing an absent token counts as made).
    @discardableResult
    static func setToken(_ token: String?, for server: UUID) -> Bool { setString(token, account: server.uuidString) }

    private static func setString(_ token: String?, account: String) -> Bool {
        if let file = KeychainNamespace.debugFileStore(service: service) {
            return (try? file.save(token.map { Data($0.utf8) }, account: account)) != nil
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let token else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            // Readable after the first unlock (background sync works), never copied to other devices.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return updated == errSecSuccess
    }
}
