import Foundation
import Security

/// Small secrets kept between launches: device keys, the session token, the sync key.
public protocol SecretStore: Sendable {
    /// The value stored for `account`, or nil when there is none.
    func load(account: String) throws -> Data?
    /// Replaces the value stored for `account`. Passing nil removes it.
    func save(_ data: Data?, account: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

/// Generic-password items in the login Keychain, one service per caller. Items are readable after the
/// first unlock and stay on this Mac: they are never synced to iCloud Keychain.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return out as? Data
    }

    public func save(_ data: Data?, account: String) throws {
        let query = baseQuery(account: account)
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw SecretStoreError.keychain(deleted)
        }
        guard let data else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

/// In-memory store for tests and previews. Nothing is written to disk.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    // @unchecked: `items` is guarded by `lock`.
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func load(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    public func save(_ data: Data?, account: String) throws {
        lock.withLock { items[account] = data }
    }
}
