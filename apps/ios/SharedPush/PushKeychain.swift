import CryptoKit
import Foundation
import Security

// What the app and the notification extension share about push: the keys of the servers and the address the cloud gave
// the phone, in the Keychain under the App Group's access group. This folder is compiled into both targets.

/// The App Group both targets belong to. The Keychain's access group is the same string (an app group is a valid
/// access group on iOS), and the plain values (`PushShared`) live in the group's UserDefaults.
enum PushGroup {
    static let identifier = "group.dev.bandito.ios"
}

/// A place for small secrets, by account name. The system's is the Keychain; tests use memory.
protocol PushSecrets: Sendable {
    func load(account: String) throws -> Data?
    /// Replaces the value; nil removes it.
    func save(_ data: Data?, account: String) throws
    /// Every account with its value.
    func all() throws -> [String: Data]
}

struct PushSecretsError: Error, Equatable {
    let status: OSStatus
}

/// Generic-password items shared through the App Group. Readable after the first unlock (the extension runs while the
/// phone is locked), never copied to another device or to iCloud.
struct SystemPushSecrets: PushSecrets {
    static let service = "dev.bandito.ios.push"
    let group: String?

    init(group: String? = PushGroup.identifier) {
        self.group = group
    }

    private func base(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    func load(account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PushSecretsError(status: status) }
        return out as? Data
    }

    func save(_ data: Data?, account: String) throws {
        let query = base(account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PushSecretsError(status: status) }
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
            guard status == errSecSuccess else { throw PushSecretsError(status: status) }
            return
        }
        guard updated == errSecSuccess else { throw PushSecretsError(status: updated) }
    }

    func all() throws -> [String: Data] {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw PushSecretsError(status: status) }
        var result: [String: Data] = [:]
        for item in (out as? [[String: Any]]) ?? [] {
            if let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data {
                result[account] = data
            }
        }
        return result
    }
}

/// In memory, for tests.
final class MemoryPushSecrets: PushSecrets, @unchecked Sendable {
    // @unchecked: `items` is guarded by `lock`.
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// When set, every write throws it (a Keychain that refuses).
    var failure: PushSecretsError?

    func load(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func save(_ data: Data?, account: String) throws {
        try lock.withLock {
            if let failure { throw failure }
            items[account] = data
        }
    }

    func all() throws -> [String: Data] {
        lock.withLock { items }
    }
}

/// What the cloud knows of this phone: the Apple token (hex), the environment it is valid in, and the address the cloud
/// gave back for them.
struct PushRegistration: Equatable, Sendable {
    var token: String
    var env: String
    var handle: String
    /// The cloud refused `env` for this token (409) and took the other one: this is the one that works, so a later launch
    /// does not try the first again.
    var envFixed = false
}

/// The push secrets of this phone: one 32-byte key per server (`push.key.<serverRef>`), and the cloud address
/// (`push.handle`, with the `push.token` and `push.env` it was made for).
struct PushKeychain: Sendable {
    static let shared = PushKeychain(secrets: SystemPushSecrets())

    static let keyPrefix = "push.key."
    static let handleAccount = "push.handle"
    static let tokenAccount = "push.token"
    static let envAccount = "push.env"
    static let registeredAtAccount = "push.registeredAt"
    static let envFixedAccount = "push.envFixed"
    static let previousHandleAccount = "push.handle.prev"
    static let previousHandleAtAccount = "push.handle.prevAt"
    /// A handle that was replaced is still opened for this long: pushes that were on their way when it changed.
    static let previousHandleLife: TimeInterval = 7 * 24 * 3600
    static let keyBytes = 32

    let secrets: PushSecrets

    init(secrets: PushSecrets) {
        self.secrets = secrets
    }

    // MARK: keys

    /// The key of a server, or nil when there is none (or what is stored is not 32 bytes).
    func key(for serverRef: String) -> SymmetricKey? {
        guard let data = try? secrets.load(account: Self.keyPrefix + serverRef), data.count == Self.keyBytes else { return nil }
        return SymmetricKey(data: data)
    }

    /// The key of a server; a new random one is made and kept when there is none. Throws when the Keychain refuses
    /// to keep it (a key the extension could not read is no key).
    func keyCreating(for serverRef: String) throws -> SymmetricKey {
        if let existing = key(for: serverRef) { return existing }
        let made = SymmetricKey(size: .bits256)
        try save(made, for: serverRef)
        return made
    }

    func save(_ key: SymmetricKey, for serverRef: String) throws {
        try secrets.save(key.withUnsafeBytes { Data($0) }, account: Self.keyPrefix + serverRef)
    }

    func deleteKey(for serverRef: String) {
        try? secrets.save(nil, account: Self.keyPrefix + serverRef)
    }

    /// The servers that have a key.
    func serverRefs() -> [String] {
        ((try? secrets.all()) ?? [:]).keys.filter { $0.hasPrefix(Self.keyPrefix) }
            .map { String($0.dropFirst(Self.keyPrefix.count)) }.sorted()
    }

    /// Every key with its server, for the extension: it tries them one by one.
    func allKeys() -> [(serverRef: String, key: SymmetricKey)] {
        let items = (try? secrets.all()) ?? [:]
        return items.compactMap { account, data in
            guard account.hasPrefix(Self.keyPrefix), data.count == Self.keyBytes else { return nil }
            return (String(account.dropFirst(Self.keyPrefix.count)), SymmetricKey(data: data))
        }.sorted { $0.serverRef < $1.serverRef }
    }

    // MARK: the cloud address

    /// The address the cloud gave this phone: what the extension decrypts with (the associated data names it).
    var handle: String? {
        (try? secrets.load(account: Self.handleAccount)).flatMap { String(data: $0, encoding: .utf8) }.flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    /// The whole registration, or nil when any of its parts is missing.
    func registration() -> PushRegistration? {
        func text(_ account: String) -> String? {
            (try? secrets.load(account: account)).flatMap { String(data: $0, encoding: .utf8) }.flatMap {
                $0.isEmpty ? nil : $0
            }
        }
        guard let token = text(Self.tokenAccount), let env = text(Self.envAccount), let handle = text(Self.handleAccount)
        else { return nil }
        let fixed = (try? secrets.load(account: Self.envFixedAccount)).flatMap { String(data: $0, encoding: .utf8) } == "1"
        return PushRegistration(token: token, env: env, handle: handle, envFixed: fixed)
    }

    /// The handle this one replaced, while it is younger than a week: the extension still opens a push sealed with it.
    func previousHandle(now: Date = Date()) -> String? {
        guard let handle = (try? secrets.load(account: Self.previousHandleAccount)).flatMap({ String(data: $0, encoding: .utf8) }),
            !handle.isEmpty,
            let at = (try? secrets.load(account: Self.previousHandleAtAccount)).flatMap({ String(data: $0, encoding: .utf8) })
                .flatMap(TimeInterval.init),
            now.timeIntervalSince1970 - at < Self.previousHandleLife
        else { return nil }
        return handle
    }

    /// The handles a push may be sealed with: the current one, then the one before it.
    func openableHandles(now: Date = Date()) -> [String] {
        [handle, previousHandle(now: now)].compactMap { $0 }
    }

    func clearPreviousHandle() {
        for account in [Self.previousHandleAccount, Self.previousHandleAtAccount] { try? secrets.save(nil, account: account) }
    }

    /// When the cloud last answered a registration, if the Keychain says.
    var registeredAt: Date? {
        (try? secrets.load(account: Self.registeredAtAccount)).flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }

    /// Keeps the registration. The handle goes last: a registration is whole only when it is there.
    func save(_ registration: PushRegistration, at date: Date = Date()) throws {
        // The handle that is replaced is kept for a while (`previousHandle`).
        if let old = handle, old != registration.handle {
            try secrets.save(Data(old.utf8), account: Self.previousHandleAccount)
            try secrets.save(Data(String(date.timeIntervalSince1970).utf8), account: Self.previousHandleAtAccount)
        }
        try secrets.save(registration.envFixed ? Data("1".utf8) : nil, account: Self.envFixedAccount)
        try secrets.save(Data(registration.token.utf8), account: Self.tokenAccount)
        try secrets.save(Data(registration.env.utf8), account: Self.envAccount)
        try secrets.save(Data(String(date.timeIntervalSince1970).utf8), account: Self.registeredAtAccount)
        try secrets.save(Data(registration.handle.utf8), account: Self.handleAccount)
    }

    func clearRegistration() {
        for account in [Self.handleAccount, Self.tokenAccount, Self.envAccount, Self.registeredAtAccount, Self.envFixedAccount] {
            try? secrets.save(nil, account: account)
        }
        clearPreviousHandle()
    }
}
