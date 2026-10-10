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
    @Test func theHeightFollowsTheRatioAndStopsAt220() {
        #expect(BrowserRunPreview.height(width: 320, aspect: 1.6) == 200)
        #expect(BrowserRunPreview.height(width: 600, aspect: 1.6) == 220)
        #expect(BrowserRunPreview.height(width: 400, aspect: 0.5) == 220)
    }

    @Test func aBadWidthGivesNoHeight() {
        #expect(BrowserRunPreview.height(width: 0, aspect: 1.6) == 0)
        #expect(BrowserRunPreview.height(width: .infinity, aspect: 1.6) == 0)
        #expect(BrowserRunPreview.height(width: 300, aspect: 0) == 0)
    }

    @Test func theRatioComesFromThePageAndStaysSane() {
        #expect(BrowserRunPreview.aspect(of: CGSize(width: 1600, height: 1000)) == 1.6)
        #expect(BrowserRunPreview.aspect(of: .zero) == BrowserRunPreview.placeholderAspect)
        #expect(BrowserRunPreview.aspect(of: CGSize(width: 100, height: 5000)) == 0.4)
        #expect(BrowserRunPreview.aspect(of: CGSize(width: 5000, height: 100)) == 3)
        #expect(BrowserRunPreview.aspect(of: CGSize(width: CGFloat.nan, height: 100)) == BrowserRunPreview.placeholderAspect)
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
