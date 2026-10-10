import Testing

@testable import BanditoUI

@MainActor
@Suite struct RouterTests {
    @Test func switchingModeKeepsSelections() {
        let router = Router()
        router.selectedAgentID = "forge"
        router.filesPath = "/home/me/billing"
        router.select(mode: .files)
        router.select(mode: .team)
        #expect(router.mode == .team)
        #expect(router.selectedAgentID == "forge")
        #expect(router.filesPath == "/home/me/billing")
    }

    @Test func selectingTheCurrentModeIsNoOp() {
        let router = Router()
        router.select(mode: .team)
        #expect(router.mode == .team)
        #expect(!router.canGoBack)
    }

    // Files is not in these: there back and forward walk its folder history (see FilesNavigationTests).
    @Test func backAndForwardWalkTheModes() {
        let router = Router()
        router.select(mode: .browser)
        router.select(mode: .terminals)

        router.back()
        #expect(router.mode == .browser)
        #expect(router.canGoForward)

        router.back()
        #expect(router.mode == .team)
        #expect(!router.canGoBack)

        router.forward()
        #expect(router.mode == .browser)
        router.forward()
        #expect(router.mode == .terminals)
        #expect(!router.canGoForward)
    }

    @Test func newSelectionDropsForwardHistory() {
        let router = Router()
        router.select(mode: .browser)
        router.back()
        #expect(router.canGoForward)

        router.select(mode: .browser)
        #expect(!router.canGoForward)
        #expect(router.canGoBack)
    }

    @Test func backWithoutHistoryDoesNothing() {
        let router = Router()
        router.back()
        router.forward()
        #expect(router.mode == .team)
    }

    @Test func everyModeHasTitleAndIcon() {
        #expect(AppMode.allCases.count == 7)
        for mode in AppMode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(!mode.systemImage.isEmpty)
        }
    }

    @Test func panelsStartClosed() {
        let router = Router()
        #expect(router.sheet == nil)
        #expect(!router.paletteOpen)
        #expect(!router.usagePopoverOpen)
        #expect(!router.inspectorOpen)
        #expect(router.sidebarVisible)
        #expect(router.serverSection == .overview)
    }
}
