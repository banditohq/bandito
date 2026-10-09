import Foundation
import Testing

@testable import BanditoKit

@Suite struct BrowserAddressTests {
    private func opened(_ typed: String) -> String? {
        if case .open(let url) = BrowserAddress.destination(for: typed) { return url }
        return nil
    }

    private func isRefused(_ typed: String) -> Bool {
        BrowserAddress.destination(for: typed) == .refused
    }

    @Test func emptyTextOpensNothing() {
        #expect(BrowserAddress.destination(for: "") == .nothing)
        #expect(BrowserAddress.destination(for: "   \n") == .nothing)
    }

    // MARK: Schemes

    @Test func httpAndHttpsOpenAsTyped() {
        #expect(opened("http://example.com") == "http://example.com")
        #expect(opened("https://example.com/a?b=1") == "https://example.com/a?b=1")
        #expect(opened("HTTPS://EXAMPLE.COM") == "HTTPS://EXAMPLE.COM")
        #expect(opened("https://котики.рф/") == "https://котики.рф/")
    }

    @Test func aboutBlankOpens() {
        #expect(opened("about:blank") == "about:blank")
    }

    @Test func fileSchemeIsRefused() {
        #expect(isRefused("file:///etc/passwd"))
        #expect(isRefused("file:/etc/hosts"))
    }

    @Test func chromeSchemeIsRefused() {
        #expect(isRefused("chrome://settings"))
        #expect(isRefused("chrome://newtab/"))
    }

    @Test func javascriptSchemeIsRefused() {
        #expect(isRefused("javascript:alert(1)"))
        #expect(isRefused("JavaScript:alert(document.cookie)"))
    }

    @Test func dataSchemeIsRefused() {
        #expect(isRefused("data:text/html,<script>alert(1)</script>"))
    }

    @Test func mailtoSchemeIsRefused() {
        #expect(isRefused("mailto:someone@example.com"))
    }

    @Test func otherSchemesAreRefused() {
        #expect(isRefused("ftp://example.com/file"))
        #expect(isRefused("blob:https://example.com/uuid"))
        #expect(isRefused("view-source:https://example.com"))
        #expect(isRefused("about:srcdoc"))
        #expect(isRefused("http:example.com"))
    }

    // MARK: Addresses without a scheme

    @Test func domainGetsHttps() {
        #expect(opened("example.com") == "https://example.com")
        #expect(opened("  example.com/a?b=1  ") == "https://example.com/a?b=1")
    }

    @Test func domainWithHttpInTheQueryGetsHttps() {
        #expect(opened("example.com/?u=http://x") == "https://example.com/?u=http://x")
    }

    @Test func localhostGetsHttp() {
        #expect(opened("localhost") == "http://localhost")
        #expect(opened("localhost:3000") == "http://localhost:3000")
        #expect(opened("localhost:3000/app?x=1") == "http://localhost:3000/app?x=1")
    }

    @Test func ipv4GetsHttp() {
        #expect(opened("192.168.1.5") == "http://192.168.1.5")
        #expect(opened("127.0.0.1:8080") == "http://127.0.0.1:8080")
    }

    @Test func hostAndPortWithoutSchemeGetsHttp() {
        #expect(opened("example.com:8080") == "http://example.com:8080")
        #expect(opened("myserver:9000/x") == "http://myserver:9000/x")
    }

    // MARK: Searches

    @Test func wordWithoutADotIsASearch() {
        #expect(
            opened("котики")
                == "https://www.google.com/search?q=%D0%BA%D0%BE%D1%82%D0%B8%D0%BA%D0%B8")
    }

    @Test func textWithSpacesIsASearchWithEveryReservedCharacterEncoded() {
        #expect(opened("a&b c+d=e") == "https://www.google.com/search?q=a%26b%20c%2Bd%3De")
    }

    @Test func phraseWithADotStillSearches() {
        #expect(opened("node.js tutorial") == "https://www.google.com/search?q=node.js%20tutorial")
    }

    @Test func schemeLikeTextWithSpacesIsASearchNotARefusal() {
        #expect(opened("javascript :alert") == "https://www.google.com/search?q=javascript%20%3Aalert")
    }
}
