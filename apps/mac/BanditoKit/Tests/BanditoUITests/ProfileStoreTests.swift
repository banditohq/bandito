import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@MainActor
@Suite struct ProfileStoreTests {
    static func defaults() -> UserDefaults {
        let suite = "profile-store-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func nicknameAndColorAreKeptPerAccount() {
        let defaults = Self.defaults()
        let store = ProfileStore(defaults: defaults)
        store.bind(userID: "u1")
        store.setNickname("  Ann  ")
        store.setColorIndex(3)
        #expect(defaults.string(forKey: "profile.nickname.u1") == "Ann")
        #expect(defaults.object(forKey: "profile.avatarColor.u1") as? Int == 3)

        store.bind(userID: "u2")
        #expect(store.nickname == "")
        #expect(store.colorIndex == 0)

        store.bind(userID: "u1")
        #expect(store.nickname == "Ann")
        #expect(store.colorIndex == 3)
    }

    @Test func theLastAccountIsRememberedForTheNextStartUntilSignOut() {
        let defaults = Self.defaults()
        let store = ProfileStore(defaults: defaults)
        #expect(store.rememberedUserID == nil)
        store.bind(userID: "u1")
        store.setNickname("Ann")

        // A new run: the nickname shows from this Mac before the server has answered.
        let next = ProfileStore(defaults: defaults)
        #expect(next.rememberedUserID == "u1")
        next.bind(userID: next.rememberedUserID)
        #expect(next.nickname == "Ann")

        // Sign-out: nobody is shown, and the next run remembers nobody.
        next.forget()
        #expect(next.userID == nil)
        #expect(next.nickname == "")
        #expect(ProfileStore(defaults: defaults).rememberedUserID == nil)
    }

    @Test func nothingIsStoredWithoutAnAccount() {
        let defaults = Self.defaults()
        let store = ProfileStore(defaults: defaults)
        store.setNickname("Ann")
        store.setColorIndex(2)
        #expect(store.nickname == "")
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("profile.") })
    }

    @Test func clearRemovesTheCurrentAccountsValues() {
        let defaults = Self.defaults()
        let store = ProfileStore(defaults: defaults)
        store.bind(userID: "u1")
        store.setNickname("Ann")
        store.setColorIndex(1)
        store.clear()
        #expect(store.nickname == "")
        #expect(store.colorIndex == 0)
        #expect(defaults.string(forKey: "profile.nickname.u1") == nil)
        #expect(defaults.object(forKey: "profile.avatarColor.u1") == nil)
    }

    @Test func blankNicknameRemovesTheStoredOne() {
        let defaults = Self.defaults()
        let store = ProfileStore(defaults: defaults)
        store.bind(userID: "u1")
        store.setNickname("Ann")
        store.setNickname("   ")
        #expect(defaults.string(forKey: "profile.nickname.u1") == nil)
    }

    @Test func displayNamePrefersNicknameThenAccountNameThenEmail() {
        let user = AccountUser(id: "u1", email: "a@x.dev", name: "Ann GH", githubLogin: nil)
        #expect(ProfileNames.displayName(nickname: "Nick", account: user) == "Nick")
        #expect(ProfileNames.displayName(nickname: "", account: user) == "Ann GH")
        #expect(ProfileNames.displayName(nickname: nil, account: AccountUser(id: "u1", email: "a@x.dev", name: nil, githubLogin: nil)) == "a@x.dev")
    }
}
