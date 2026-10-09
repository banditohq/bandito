import Foundation
import Testing

@testable import BanditoUI

// A server's token is replaced in place (SecItemUpdate, add when there is none), the way SecretStore does it.
@MainActor
@Test func aServersTokenCanBeReplacedAndCleared() {
    let id = UUID()
    defer { Keychain.setToken(nil, for: id) }
    #expect(Keychain.setToken("first", for: id))
    #expect(Keychain.token(for: id) == "first")
    #expect(Keychain.setToken("second", for: id))
    #expect(Keychain.token(for: id) == "second")
    #expect(Keychain.setToken(nil, for: id))
    #expect(Keychain.token(for: id) == nil)
}
