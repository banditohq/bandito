import BanditoKit
import Testing

@testable import BanditoUI

@Suite struct BrowserSidebarLogicTests {
    @Test func noStripWhenNobodyHoldsTheBrowser() {
        #expect(BrowserControlNote.make(holder: .none, asksToTake: false) == nil)
        #expect(BrowserControlNote.make(holder: .none, asksToTake: true) == nil)
    }

    @Test func agentDrivingStripNamesTheAgentState() {
        #expect(BrowserControlNote.make(holder: .agent, asksToTake: false) == .agentDriving)
        #expect(BrowserControlNote.make(holder: .agent, asksToTake: true) == .askToTake)
    }

    @Test func userHoldingShowsAQuietStrip() {
        #expect(BrowserControlNote.make(holder: .user, asksToTake: false) == .userHolds)
    }

    @Test func tabWithTitleShowsTheTitleAndDomain() {
        let parts = BrowserTabLabel.make(title: "  Google ", url: "https://www.google.com/search?q=x", newTabTitle: "New tab")
        #expect(parts.title == "Google")
        #expect(parts.domain == "google.com")
        #expect(parts.initial == "G")
    }

    @Test func tabWithoutTitleShowsItsDomain() {
        let parts = BrowserTabLabel.make(title: "", url: "https://example.org/a", newTabTitle: "New tab")
        #expect(parts.title == "example.org")
        #expect(parts.domain == "example.org")
    }

    @Test func titleEqualToTheAddressCountsAsNoTitle() {
        let parts = BrowserTabLabel.make(title: "https://example.org/", url: "https://example.org/", newTabTitle: "New tab")
        #expect(parts.title == "example.org")
    }

    @Test func blankAndNewTabPagesShowTheNewTabName() {
        let blank = BrowserTabLabel.make(title: "", url: "about:blank", newTabTitle: "New tab")
        #expect(blank.title == "New tab")
        #expect(blank.domain.isEmpty)
        let newtab = BrowserTabLabel.make(title: "New Tab", url: "chrome://newtab/", newTabTitle: "New tab")
        #expect(newtab.domain.isEmpty)
        #expect(BrowserTabLabel.isBlank("chrome://newtab/"))
        #expect(!BrowserTabLabel.isBlank("https://google.com"))
    }

    @MainActor
    @Test func historyEntriesAreReadFromTheReply() {
        let history: JSONValue = .object([
            "currentIndex": .number(1),
            "entries": .array([
                .object(["id": .number(1), "url": .string("chrome://newtab/")]),
                .object(["id": .number(2), "url": .string("https://www.google.com/")]),
            ]),
        ])
        let entries = BrowserModel.historyEntries(history)
        #expect(entries.count == 2)
        #expect(entries[1]["url"]?.string == "https://www.google.com/")
        #expect(BrowserModel.historyEntries(.object([:])).isEmpty)
    }

    @Test func blankPageAlwaysShowsTheNewTabNameEvenWithAPageTitle() {
        let parts = BrowserTabLabel.make(title: "Something", url: "about:blank", newTabTitle: "New tab")
        #expect(parts.title == "New tab")
        #expect(parts.domain.isEmpty)
    }

    @Test func closingAShownTabShowsTheNeighbourOnTheRight() {
        let outcome = BrowserTabPolicy.afterClosing(
            closedID: "b", shownID: "b", before: ["a", "b", "c"], remaining: ["a", "c"])
        #expect(outcome == .show("c"))
    }

    @Test func closingTheLastShownTabShowsTheLeftOne() {
        let outcome = BrowserTabPolicy.afterClosing(
            closedID: "c", shownID: "c", before: ["a", "b", "c"], remaining: ["a", "b"])
        #expect(outcome == .show("b"))
    }

    @Test func closingTheOnlyTabOpensABlankOne() {
        let outcome = BrowserTabPolicy.afterClosing(closedID: "a", shownID: "a", before: ["a"], remaining: [])
        #expect(outcome == .openBlank)
    }

    @Test func closingAnotherTabKeepsTheShownOne() {
        let outcome = BrowserTabPolicy.afterClosing(
            closedID: "a", shownID: "b", before: ["a", "b"], remaining: ["b"])
        #expect(outcome == .keep)
    }

    @Test func pageMovesUpdateTheAddressWhenNotTyping() {
        let next = BrowserAddressRule.afterPageMoved(
            to: "https://www.google.com/", currentURL: "chrome://newtab/", typed: "goo", editing: false)
        #expect(next == .init(currentURL: "https://www.google.com/", typed: "https://www.google.com/"))
    }

    @Test func pageMovesDoNotOverwriteWhatIsBeingTyped() {
        let next = BrowserAddressRule.afterPageMoved(
            to: "https://www.google.com/", currentURL: "chrome://newtab/", typed: "goo", editing: true)
        #expect(next == .init(currentURL: "https://www.google.com/", typed: "goo"))
    }

    @Test func sameURLChangesNothing() {
        let next = BrowserAddressRule.afterPageMoved(
            to: "https://a.test/", currentURL: "https://a.test/", typed: "a.te", editing: true)
        #expect(next == .init(currentURL: "https://a.test/", typed: "a.te"))
    }

    @Test func leavingTheFieldShowsThePageAddressAgain() {
        #expect(BrowserAddressRule.afterEditingEnded(currentURL: "https://a.test/", typed: "a.te", editing: false) == "https://a.test/")
        #expect(BrowserAddressRule.afterEditingEnded(currentURL: "https://a.test/", typed: "a.te", editing: true) == "a.te")
    }

    @Test func tabTitleFollowsTheLivePageTitleAndShowsItsDomain() {
        let parts = BrowserTabLabel.make(title: "Example Domain", url: "https://www.example.com/", newTabTitle: "New tab")
        #expect(parts.title == "Example Domain")
        #expect(parts.domain == "example.com")
    }

    @Test func newTabAddressIsAnEmptyField() {
        #expect(BrowserAddressRule.shownAddress("chrome://newtab/").isEmpty)
        #expect(BrowserAddressRule.shownAddress("about:blank").isEmpty)
        #expect(BrowserAddressRule.shownAddress("https://a.test/") == "https://a.test/")
    }

    @Test func movingToANewTabClearsTheFieldWhenNotTyping() {
        let next = BrowserAddressRule.afterPageMoved(
            to: "about:blank", currentURL: "https://a.test/", typed: "a.te", editing: false)
        #expect(next == .init(currentURL: "about:blank", typed: ""))
    }

    @Test func leavingTheFieldOnANewTabShowsAnEmptyField() {
        #expect(BrowserAddressRule.afterEditingEnded(currentURL: "chrome://newtab/", typed: "x", editing: false).isEmpty)
    }

    @Test func newTabPagesAlwaysShowTheLocalizedNewTabName() {
        for url in ["about:blank", "chrome://newtab/", "chrome-search://local-ntp/local-ntp.html", "CHROME://NEWTAB/"] {
            let parts = BrowserTabLabel.make(title: "Something Else", url: url, newTabTitle: "Новая вкладка")
            #expect(parts.title == "Новая вкладка")
            #expect(parts.domain.isEmpty)
        }
    }
}
