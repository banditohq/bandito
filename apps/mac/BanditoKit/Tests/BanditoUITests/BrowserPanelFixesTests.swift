import BanditoKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import BanditoUI

@Suite struct BrowserAddressSourceTests {
    @Test func aTabFillsAnEmptyAddress() {
        #expect(BrowserAddressRule.fillFromTab(currentURL: "", tabURL: "https://myip.com/") == "https://myip.com/")
        #expect(BrowserAddressRule.fillFromTab(currentURL: "about:blank", tabURL: "https://a.example/") == "https://a.example/")
    }

    @Test func aTabNeverReplacesAnAddressThePageAlreadyHas() {
        // The list of tabs may be older than the page's own events.
        #expect(BrowserAddressRule.fillFromTab(currentURL: "https://new.example/", tabURL: "https://old.example/") == nil)
    }

    @Test func aBlankTabFillsNothing() {
        #expect(BrowserAddressRule.fillFromTab(currentURL: "", tabURL: "about:blank") == nil)
        #expect(BrowserAddressRule.fillFromTab(currentURL: "", tabURL: "") == nil)
        #expect(BrowserAddressRule.fillFromTab(currentURL: "", tabURL: nil) == nil)
    }

    @Test func theCurrentHistoryEntryIsTheAddress() throws {
        let history = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"currentIndex":1,"entries":[{"id":1,"url":"https://a.example/"},{"id":2,"url":"https://captcha.2gis.ru/x"}]}"#
                    .utf8))
        #expect(BrowserAddressRule.currentEntryURL(history) == "https://captcha.2gis.ru/x")
    }

    @Test func anOddHistoryGivesNoAddress() throws {
        let empty = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"currentIndex":0,"entries":[]}"#.utf8))
        #expect(BrowserAddressRule.currentEntryURL(empty) == nil)
        let outside = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"currentIndex":5,"entries":[{"id":1,"url":"https://a.example/"}]}"#.utf8))
        #expect(BrowserAddressRule.currentEntryURL(outside) == nil)
        #expect(BrowserAddressRule.currentEntryURL(.null) == nil)
    }

    @Test func aFocusedButUntouchedFieldStillFollowsThePage() {
        // The panel's field may hold the focus without the person typing: it must not stay empty.
        let next = BrowserAddressRule.afterPageMoved(
            to: "https://example.com/", currentURL: "about:blank", typed: "", editing: true)
        #expect(next == .init(currentURL: "https://example.com/", typed: "https://example.com/"))
    }

    @Test func anEmptyFieldIsRepairedBySameAddress() {
        let next = BrowserAddressRule.afterPageMoved(
            to: "https://example.com/", currentURL: "https://example.com/", typed: "", editing: false)
        #expect(next.typed == "https://example.com/")
    }

    @Test func aClearedFieldBeingTypedInIsKept() {
        let next = BrowserAddressRule.afterPageMoved(
            to: "https://b.example/", currentURL: "https://a.example/", typed: "", editing: true)
        #expect(next.typed == "")
    }

    @Test func theTypedTextSurvivesAPageMoveWhileEditing() {
        let next = BrowserAddressRule.afterPageMoved(
            to: "https://b.example/", currentURL: "https://a.example/", typed: "my sear", editing: true)
        #expect(next.currentURL == "https://b.example/")
        #expect(next.typed == "my sear")
    }
}

@Suite struct BrowserClosedByPersonTests {
    @Test func closingTheBrowserTabSilencesTheChat() {
        let open = WorkbenchRules.open(.browser, in: WorkbenchState())
        #expect(WorkbenchRules.showsBrowserChip(state: open, runningTools: ["browser_open"]) == false)  // on show
        let closed = WorkbenchRules.close(.browser, in: open)
        #expect(closed.browserDismissed)
        #expect(!WorkbenchRules.showsBrowserChip(state: closed, runningTools: ["browser_open"]))
    }

    @Test func openingTheBrowserAgainOffersItAgain() {
        let closed = WorkbenchRules.close(.browser, in: WorkbenchRules.open(.browser, in: WorkbenchState()))
        let reopened = WorkbenchRules.open(.browser, in: closed)
        #expect(!reopened.browserDismissed)
        var panelClosed = reopened
        panelClosed.isOpen = false
        #expect(WorkbenchRules.showsBrowserChip(state: panelClosed, runningTools: ["browser_open"]))
    }

    @Test func closingAnotherTabDismissesNothing() {
        let state = WorkbenchRules.open(.changes, in: WorkbenchRules.open(.browser, in: WorkbenchState()))
        let next = WorkbenchRules.close(.changes, in: state)
        #expect(!next.browserDismissed)
    }

    @Test func closingThePanelDoesNotCountAsClosingTheTab() {
        var state = WorkbenchRules.open(.browser, in: WorkbenchState())
        state.isOpen = false
        #expect(!state.browserDismissed)
        #expect(WorkbenchRules.showsBrowserChip(state: state, runningTools: ["browser_open"]))
    }
}

@Suite struct BrowserRunPreviewTests {
    @Test func thePictureIsAlways200TallWhateverTheWidth() {
        #expect(BrowserRunPreview.height(width: 320) == 200)
        #expect(BrowserRunPreview.height(width: 600) == 200)
        #expect(BrowserRunPreview.height(width: 1) == 200)
    }

    @Test func aBadWidthGivesNoHeight() {
        #expect(BrowserRunPreview.height(width: 0) == 0)
        #expect(BrowserRunPreview.height(width: -10) == 0)
        #expect(BrowserRunPreview.height(width: .infinity) == 0)
        #expect(BrowserRunPreview.height(width: .nan) == 0)
    }
}

@Suite struct BrowserFrameCropTests {
    private let card = CGSize(width: 300, height: 200)

    @Test func aTallPageIsCutFromTheBottomSoTheTopShows() {
        // 1:2 page in a 3:2 card: the full width is used, the top 1/3 of the page height is kept. The unit square
        // counts y from the bottom, so the top third starts at 2/3.
        let rect = BrowserFrameCrop.topFill(view: card, picture: CGSize(width: 1000, height: 2000))
        #expect(rect.origin.x == 0)
        #expect(abs(rect.origin.y - 2.0 / 3.0) < 0.0001)
        #expect(rect.width == 1)
        #expect(abs(rect.height - 1.0 / 3.0) < 0.0001)
        #expect(abs(rect.maxY - 1) < 0.0001)
    }

    @Test func aWidePageIsCutFromBothSidesEvenly() {
        // 4:1 page in a 3:2 card: the full height is used, the middle 3/8 of the width is kept.
        let rect = BrowserFrameCrop.topFill(view: card, picture: CGSize(width: 4000, height: 1000))
        #expect(rect.origin.y == 0)
        #expect(rect.height == 1)
        #expect(abs(rect.width - 0.375) < 0.0001)
        #expect(abs(rect.origin.x - 0.3125) < 0.0001)
    }

    @Test func aPageWithTheCardsRatioIsShownWhole() {
        let rect = BrowserFrameCrop.topFill(view: card, picture: CGSize(width: 900, height: 600))
        #expect(rect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func aBadSizeGivesTheWholePicture() {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(BrowserFrameCrop.topFill(view: card, picture: .zero) == whole)
        #expect(BrowserFrameCrop.topFill(view: .zero, picture: CGSize(width: 10, height: 10)) == whole)
        #expect(BrowserFrameCrop.topFill(view: card, picture: CGSize(width: CGFloat.nan, height: 10)) == whole)
    }
}

@Suite struct BrowserToolbarLayoutTests {
    @Test func aNarrowToolbarShowsOpenOnMacAsAnIcon() {
        #expect(BrowserToolbarLayout.opensOnMacAsIcon(width: 360))
        #expect(BrowserToolbarLayout.opensOnMacAsIcon(width: 519.5))
    }

    @Test func aWideToolbarKeepsTheText() {
        #expect(!BrowserToolbarLayout.opensOnMacAsIcon(width: 520))
        #expect(!BrowserToolbarLayout.opensOnMacAsIcon(width: 900))
    }

    @Test func aWidthNotMeasuredYetKeepsTheText() {
        #expect(!BrowserToolbarLayout.opensOnMacAsIcon(width: 0))
        #expect(!BrowserToolbarLayout.opensOnMacAsIcon(width: .nan))
        #expect(!BrowserToolbarLayout.opensOnMacAsIcon(width: .infinity))
    }
}

@Suite @MainActor struct BrowserFrameStoreTests {
    private func image(_ side: Int) -> CGImage? {
        CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }

    @Test func listenersGetTheCurrentAndEveryNewPicture() throws {
        let store = BrowserFrameStore()
        var seen: [CGImage?] = []
        let id = UUID()
        let first = try #require(image(2))
        store.set(first)
        store.listen(id) { seen.append($0) }
        #expect(seen.count == 1)
        let second = try #require(image(3))
        store.set(second)
        #expect(seen.count == 2)
        #expect(store.image === second)
    }

    @Test func theSamePictureIsNotSentTwiceAndAStoppedListenerGetsNothing() throws {
        let store = BrowserFrameStore()
        var count = 0
        let id = UUID()
        store.listen(id) { _ in count += 1 }
        let picture = try #require(image(2))
        store.set(picture)
        store.set(picture)
        #expect(count == 2)  // the current (none) at once, then the picture once
        store.stopListening(id)
        store.set(nil)
        #expect(count == 2)
    }

    @Test func aJPEGDecodesOffTheMainActor() async throws {
        let picture = try #require(image(4))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, picture, nil)
        #expect(CGImageDestinationFinalize(destination))
        let bytes = data as Data
        let decoded = await Task.detached { BrowserModel.decodeJPEG(bytes) }.value
        #expect(decoded?.width == 4)
        let garbage = await Task.detached { BrowserModel.decodeJPEG(Data([1, 2, 3])) }.value
        #expect(garbage == nil)
    }
}
