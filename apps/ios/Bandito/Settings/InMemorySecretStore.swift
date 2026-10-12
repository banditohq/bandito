import BanditoKit
import Foundation

/// A `SecretStore` that keeps values in memory. The demo world uses it, and tests use it with a Keychain that refuses
/// writes. The real app uses BanditoKit's `KeychainStore`.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var refusal: SecretStoreError?

    init() {}

    /// Makes every later write throw `error`; nil lets writes through again.
    func refuseWrites(_ error: SecretStoreError?) {
        lock.lock()
        defer { lock.unlock() }
        refusal = error
    }

    func load(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func save(_ data: Data?, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let refusal { throw refusal }
        values[account] = data
    }
}
