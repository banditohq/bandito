import Foundation
import Testing

@testable import BanditoUI

@Suite struct BrowserStartPageTests {
    @Test func noTabsIsItsOwnState() {
        let state = BrowserPageStateRule.make(hasTabs: false, url: "", hasFrame: false, frameWaitExpired: false)
        #expect(state == .noTabs)
        // Nothing else matters once there is no tab: an old picture or an old wait does not bring a page back.
        #expect(BrowserPageStateRule.make(hasTabs: false, url: "https://example.com", hasFrame: true, frameWaitExpired: true) == .noTabs)
    }

    @Test func aBlankTabIsTheStartPageWithoutAnyWait() {
        for url in ["about:blank", "chrome://newtab/", "chrome-search://local-ntp/local-ntp.html"] {
            #expect(BrowserPageStateRule.make(hasTabs: true, url: url, hasFrame: false, frameWaitExpired: false) == .startPage)
            // No picture comes for a blank page: after the timeout it is still the start page, not a failure.
            #expect(BrowserPageStateRule.make(hasTabs: true, url: url, hasFrame: false, frameWaitExpired: true) == .startPage)
        }
    }

    @Test func anUnknownAddressWaitsLikeAPage() {
        // The address of a tab is not read yet: it must not be taken for a blank page.
        #expect(BrowserPageStateRule.make(hasTabs: true, url: "", hasFrame: false, frameWaitExpired: false) == .waitingForFrame)
    }

    @Test func aPageWaitsForItsPictureThenTimesOut() {
        let url = "https://example.com/"
        #expect(BrowserPageStateRule.make(hasTabs: true, url: url, hasFrame: false, frameWaitExpired: false) == .waitingForFrame)
        #expect(BrowserPageStateRule.make(hasTabs: true, url: url, hasFrame: false, frameWaitExpired: true) == .frameTimedOut)
    }

    @Test func aPictureShowsThePageWhateverTheWait() {
        let url = "https://example.com/"
        #expect(BrowserPageStateRule.make(hasTabs: true, url: url, hasFrame: true, frameWaitExpired: false) == .showsPage)
        #expect(BrowserPageStateRule.make(hasTabs: true, url: url, hasFrame: true, frameWaitExpired: true) == .showsPage)
    }

    @Test func theFrameTimeoutIsTenSeconds() {
        #expect(BrowserPageStateRule.frameTimeout == .seconds(10))
    }

    @Test func recentAddressesStartWithTheNewestAndHaveNoRepeats() {
        var list: [String] = []
        list = BrowserRecentAddresses.recording("https://a.example/", into: list)
        list = BrowserRecentAddresses.recording("https://b.example/", into: list)
        list = BrowserRecentAddresses.recording("https://a.example/", into: list)
        #expect(list == ["https://a.example/", "https://b.example/"])
    }

    @Test func recentAddressesKeepEightAndDropTheOldest() {
        var list: [String] = []
        for n in 1...10 {
            list = BrowserRecentAddresses.recording("https://site\(n).example/", into: list)
        }
        #expect(list.count == BrowserRecentAddresses.limit)
        #expect(list.first == "https://site10.example/")
        #expect(list.last == "https://site3.example/")
    }

    @Test func blankAndBrowserPagesAreNotRecorded() {
        let list = ["https://a.example/"]
        #expect(BrowserRecentAddresses.recording("about:blank", into: list) == list)
        #expect(BrowserRecentAddresses.recording("chrome://newtab/", into: list) == list)
        #expect(BrowserRecentAddresses.recording("", into: list) == list)
    }

    @Test func recentAddressesAreKeptPerServerInItsDefaults() throws {
        let suite = "bandito.tests.recent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        BrowserRecentAddresses.remember("https://one.example/", serverKey: "server-1", defaults: defaults)
        BrowserRecentAddresses.remember("https://two.example/", serverKey: "server-2", defaults: defaults)
        BrowserRecentAddresses.remember("about:blank", serverKey: "server-1", defaults: defaults)
        #expect(BrowserRecentAddresses.list(serverKey: "server-1", defaults: defaults) == ["https://one.example/"])
        #expect(BrowserRecentAddresses.list(serverKey: "server-2", defaults: defaults) == ["https://two.example/"])
        #expect(BrowserRecentAddresses.list(serverKey: "server-3", defaults: defaults) == [])
    }
}
