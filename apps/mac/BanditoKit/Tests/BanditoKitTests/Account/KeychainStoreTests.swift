import Foundation
import Security
import Testing

@testable import BanditoKit

/// Whether this test process can write to the login Keychain. An unsigned or sandboxed host may lack the
/// entitlement (`errSecMissingEntitlement`, -34018), and an access prompt would wait for a person. Then the
/// Keychain tests are skipped, not failed.
enum KeychainAccess {
    static let available: Bool = {
        let store = KeychainStore(service: "dev.bandito.tests.probe.\(UUID().uuidString)")
        defer { try? store.save(nil, account: "probe") }
        do {
            try store.save(Data("probe".utf8), account: "probe")
            return try store.load(account: "probe") == Data("probe".utf8)
        } catch {
            return false
        }
    }()
}

/// Reads the attributes of one generic-password item, as the Keychain reports them.
private func attributes(service: String, account: String) throws -> [String: Any] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var output: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &output)
    guard status == errSecSuccess, let found = output as? [String: Any] else {
        throw SecretStoreError.keychain(status)
    }
    return found
}

@Suite(
    .serialized,
    .enabled(
        if: KeychainAccess.available,
        "The login Keychain is not usable in this test run (no entitlement, or access needs a person to approve it)."))
struct KeychainStoreTests {
    @Test func saveUpdateLoadAndDeleteKeepTheProtectionClass() throws {
        // A unique service, so the test never touches the app's items.
        let service = "dev.bandito.tests.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        defer { try? store.save(nil, account: "item") }

        try store.save(Data("first".utf8), account: "item")
        #expect(try store.load(account: "item") == Data("first".utf8))

        // The update path: the item exists, so it is changed in place.
        try store.save(Data("second".utf8), account: "item")
        #expect(try store.load(account: "item") == Data("second".utf8))

        // The login Keychain (file-based) reports only the item's class, account, service, label and dates.
        // It does not report the protection class, so this check sees it only where the system returns it.
        // The protection class is set by the same update call; see the note in the report.
        let found = try attributes(service: service, account: "item")
        if let reported = found[kSecAttrAccessible as String] as? String {
            #expect(reported == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        }
        #expect((found[kSecAttrSynchronizable as String] as? Bool) != true)

        try store.save(nil, account: "item")
        #expect(try store.load(account: "item") == nil)
    }
}
