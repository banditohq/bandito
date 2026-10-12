import Foundation
import Testing

@testable import BanditoUI

@Suite struct ChatLinkRoutingTests {
    private let builtIn = ChatLinkPreferences(openTarget: .builtIn, signInInMacBrowser: true)
    private let mac = ChatLinkPreferences(openTarget: .macBrowser, signInInMacBrowser: true)
    private let plainBuiltIn = ChatLinkPreferences(openTarget: .builtIn, signInInMacBrowser: false)

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: destination

    @Test func aPlainLinkOpensInTheBuiltInBrowserByDefault() {
        #expect(ChatLinkRouting.destination(for: url("https://example.com/docs"), commandHeld: false, preferences: builtIn) == .builtIn)
    }

    @Test func commandClickTakesTheOtherBrowser() {
        #expect(ChatLinkRouting.destination(for: url("https://example.com/docs"), commandHeld: true, preferences: builtIn) == .macBrowser)
    }

    @Test func theMacBrowserSettingOpensPlainLinksInTheMacBrowser() {
        #expect(ChatLinkRouting.destination(for: url("https://example.com/docs"), commandHeld: false, preferences: mac) == .macBrowser)
    }

    @Test func commandClickWithTheMacBrowserSettingOpensTheBuiltInBrowser() {
        #expect(ChatLinkRouting.destination(for: url("https://example.com/docs"), commandHeld: true, preferences: mac) == .builtIn)
    }

    @Test func aSignInLinkOpensInTheMacBrowserAndCommandTakesTheOpposite() {
        let login = url("https://accounts.google.com/o/oauth2/v2/auth?client_id=x")
        #expect(ChatLinkRouting.destination(for: login, commandHeld: false, preferences: builtIn) == .macBrowser)
        #expect(ChatLinkRouting.destination(for: login, commandHeld: true, preferences: builtIn) == .builtIn)
        #expect(ChatLinkRouting.destination(for: login, commandHeld: false, preferences: mac) == .macBrowser)
        #expect(ChatLinkRouting.destination(for: login, commandHeld: true, preferences: mac) == .builtIn)
    }

    @Test func aSignInLinkFollowsTheRuleWhenTheSettingIsOff() {
        let login = url("https://accounts.google.com/o/oauth2/v2/auth")
        #expect(ChatLinkRouting.destination(for: login, commandHeld: false, preferences: plainBuiltIn) == .builtIn)
        #expect(ChatLinkRouting.destination(for: login, commandHeld: true, preferences: plainBuiltIn) == .macBrowser)
    }

    // MARK: sign-in classifier

    @Test func theSignInHostsAreRecognised() {
        #expect(ChatLinkRouting.isSignIn(url("https://accounts.google.com/")))
        #expect(ChatLinkRouting.isSignIn(url("https://login.microsoftonline.com/common/oauth2/v2.0/authorize")))
        #expect(ChatLinkRouting.isSignIn(url("https://appleid.apple.com/auth/authorize")))
        #expect(ChatLinkRouting.isSignIn(url("https://connect.composio.dev/link/abc")))
        #expect(ChatLinkRouting.isSignIn(url("https://tenant.auth0.com/u/login")))
    }

    @Test func aLookalikeHostIsNotASignInHost() {
        #expect(!ChatLinkRouting.isSignIn(url("https://notauth0.com/")))
        #expect(!ChatLinkRouting.isSignIn(url("https://accounts.google.com.evil.example/")))
        #expect(!ChatLinkRouting.isSignIn(url("https://composio.example.com/")))
    }

    @Test func githubLoginPagesAreSignInButTheRestOfGithubIsNot() {
        #expect(ChatLinkRouting.isSignIn(url("https://github.com/login")))
        #expect(ChatLinkRouting.isSignIn(url("https://github.com/login/oauth/authorize?client_id=x")))
        #expect(!ChatLinkRouting.isSignIn(url("https://github.com/apple/swift")))
        #expect(!ChatLinkRouting.isSignIn(url("https://github.com/")))
    }

    @Test func oauthAuthorizeAndLoginPathsOnAnyHostAreSignIn() {
        #expect(ChatLinkRouting.isSignIn(url("https://example.com/oauth/callback")))
        #expect(ChatLinkRouting.isSignIn(url("https://api.example.com/v2/authorize?x=1")))
        #expect(ChatLinkRouting.isSignIn(url("https://example.com/login")))
        #expect(ChatLinkRouting.isSignIn(url("https://example.com/OAuth/start")))
    }

    @Test func ordinaryPagesAreNotSignIn() {
        #expect(!ChatLinkRouting.isSignIn(url("https://example.com/docs/install")))
        #expect(!ChatLinkRouting.isSignIn(url("https://example.com/")))
    }

    @Test func onlyWebAddressesCanBeSignIn() {
        #expect(!ChatLinkRouting.isSignIn(url("mailto:someone@example.com")))
        #expect(!ChatLinkRouting.isSignIn(url("bandito-file://open?path=/login")))
    }

    // MARK: hint

    @Test func theHintNamesTheBuiltInBrowserAndTheCommandAlternative() {
        #expect(ChatLinkRouting.hintKind(for: url("https://example.com/docs"), commandHeld: false, preferences: builtIn) == .builtInWithCommand)
    }

    @Test func theHintNamesTheMacBrowserWhenThatIsTheSetting() {
        #expect(ChatLinkRouting.hintKind(for: url("https://example.com/docs"), commandHeld: false, preferences: mac) == .macWithCommand)
    }

    @Test func holdingCommandShowsTheOtherDestinationAlone() {
        #expect(ChatLinkRouting.hintKind(for: url("https://example.com/docs"), commandHeld: true, preferences: builtIn) == .macOnly)
        #expect(ChatLinkRouting.hintKind(for: url("https://example.com/docs"), commandHeld: true, preferences: mac) == .builtInOnly)
    }

    @Test func aSignInLinkHintsTheMacBrowserWithTheCommandAlternative() {
        let login = url("https://accounts.google.com/")
        #expect(ChatLinkRouting.hintKind(for: login, commandHeld: false, preferences: builtIn) == .macWithCommand)
        #expect(ChatLinkRouting.hintKind(for: login, commandHeld: true, preferences: builtIn) == .builtInOnly)
    }

    @Test func theHintOfALinkWithTheSignInSettingOffIsTheRuleOfTheSetting() {
        let login = url("https://accounts.google.com/")
        #expect(ChatLinkRouting.hintKind(for: login, commandHeld: false, preferences: plainBuiltIn) == .builtInWithCommand)
    }

    // MARK: stored preferences

    @Test func thePreferencesDefaultToTheBuiltInBrowserAndSignInInTheMacBrowser() {
        let store = UserDefaults(suiteName: "ChatLinkRoutingTests.\(UUID().uuidString)")!
        #expect(ChatLinkPreferences.stored(store) == ChatLinkPreferences.defaults)
        #expect(ChatLinkPreferences.defaults == ChatLinkPreferences(openTarget: .builtIn, signInInMacBrowser: true))
    }

    @Test func storedValuesAreRead() {
        let store = UserDefaults(suiteName: "ChatLinkRoutingTests.\(UUID().uuidString)")!
        store.set(ChatLinkOpenTarget.macBrowser.rawValue, forKey: ChatLinkSettings.openTargetDefaultsKey)
        store.set(false, forKey: ChatLinkSettings.signInDefaultsKey)
        #expect(ChatLinkPreferences.stored(store) == ChatLinkPreferences(openTarget: .macBrowser, signInInMacBrowser: false))
    }

    @Test func anUnknownStoredTargetFallsBackToTheBuiltInBrowser() {
        let store = UserDefaults(suiteName: "ChatLinkRoutingTests.\(UUID().uuidString)")!
        store.set("somewhereElse", forKey: ChatLinkSettings.openTargetDefaultsKey)
        #expect(ChatLinkPreferences.stored(store).openTarget == .builtIn)
    }

    // MARK: first web link of a message

    @Test func theFirstWebLinkOfAMessageDecidesTheHint() {
        var text = AttributedString("see ")
        var link = AttributedString("https://accounts.google.com/x")
        link.link = URL(string: "https://accounts.google.com/x")
        text += link
        #expect(ChatLinkRouting.firstWebLink(in: [.text(text)]) == URL(string: "https://accounts.google.com/x"))
    }

    @Test func aFileLinkAndPlainTextHaveNoWebLink() {
        var text = AttributedString("open ")
        var file = AttributedString("Composer.swift")
        file.link = ChatLinkText.fileURL(path: "Composer.swift")
        text += file
        #expect(ChatLinkRouting.firstWebLink(in: [.text(text)]) == nil)
        #expect(ChatLinkRouting.firstWebLink(in: [.text(AttributedString("no links here"))]) == nil)
        #expect(ChatLinkRouting.firstWebLink(in: [.code(language: nil, code: "https://example.com")]) == nil)
    }

    @Test func theRenderCacheKeepsTheFirstWebLinkBesideTheBlocks() {
        let rendered = MessageRenderCache.rendered("see https://example.com/docs now", markdown: false)
        #expect(rendered.firstWebLink == URL(string: "https://example.com/docs"))
        #expect(MessageRenderCache.rendered("no links", markdown: false).firstWebLink == nil)
    }
}
