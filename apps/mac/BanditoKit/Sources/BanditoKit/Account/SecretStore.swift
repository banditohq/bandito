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
        self.service = KeychainNamespace.scoped(service)
    }

    public func load(account: String) throws -> Data? {
        if let file = KeychainNamespace.debugFileStore(service: service) { return try file.load(account: account) }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return out as? Data
    }

    /// Replaces the value in place (`SecItemUpdate`), or adds it when there is none. Only `save(nil)` deletes.
    public func save(_ data: Data?, account: String) throws {
        if let file = KeychainNamespace.debugFileStore(service: service) {
            return try file.save(data, account: account)
        }
        let query = baseQuery(account: account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
            return
        }
        guard updated == errSecSuccess else { throw SecretStoreError.keychain(updated) }
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

/// Files with mode 0600 in a 0700 folder, one file per account. Only debug builds use it (see
/// `KeychainNamespace.debugFileStore`): an ad hoc signed build is a new app to the Keychain after every
/// rebuild, so the Keychain would ask for the login password each time.
public struct FileSecretStore: SecretStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(account: String) throws -> Data? {
        let url = file(for: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data?, account: String) throws {
        let url = file(for: account)
        guard let data else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func file(for account: String) -> URL {
        // Account names are ids and fixed words; hex keeps any other character out of the path.
        directory.appending(path: Data(account.utf8).map { String(format: "%02x", $0) }.joined())
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
