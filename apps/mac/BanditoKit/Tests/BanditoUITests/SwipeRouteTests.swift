import Testing

@testable import BanditoUI

@Suite struct SwipeRouteTests {
    private func action(
        _ mode: AppMode, _ direction: SwipeDirection, page: Bool = false, chat: Bool = false, home: Bool = false,
        agent: Bool = true
    ) -> SwipeAction {
        SwipeRoute.action(
            mode: mode,
            context: SwipeContext(overBrowserPage: page, chatOpen: chat, onTeamHome: home, hasAgent: agent),
            direction: direction)
    }

    @Test func theBrowserStepsThroughThePagesHistory() {
        #expect(action(.browser, .back) == .browserBack)
        #expect(action(.browser, .forward) == .browserForward)
    }

    @Test func aBrowserPageInTheAgentPanelDoesTheSame() {
        #expect(action(.team, .back, page: true, chat: true) == .browserBack)
        #expect(action(.team, .forward, page: true, chat: true) == .browserForward)
    }

    @Test func filesStepThroughFolders() {
        #expect(action(.files, .back) == .filesBack)
        #expect(action(.files, .forward) == .filesForward)
    }

    @Test func swipingRightInAChatClosesItToTheHome() {
        #expect(action(.team, .back, chat: true) == .closeChat)
        #expect(action(.team, .forward, chat: true) == .none)
    }

    @Test func swipingLeftOnTheHomeReturnsToTheAgent() {
        #expect(action(.team, .forward, home: true) == .reopenLastAgent)
        #expect(action(.team, .back, home: true) == .none)
        #expect(action(.team, .forward, home: true, agent: false) == .none)
    }

    @Test func aTeamWithNoChatDoesNothing() {
        #expect(action(.team, .back) == .none)
        #expect(action(.team, .forward) == .none)
    }

    @Test func otherModesDoNothing() {
        for mode in [AppMode.terminals, .screen, .market, .server] {
            #expect(action(mode, .back) == .none)
            #expect(action(mode, .forward) == .none)
        }
    }

    @Test func eachActionNamesItsArrow() {
        #expect(SwipeAction.none.symbol == nil)
        #expect(SwipeAction.browserBack.symbol == "chevron.left")
        #expect(SwipeAction.closeChat.symbol == "chevron.left")
        #expect(SwipeAction.reopenLastAgent.symbol == "chevron.right")
    }
}

@MainActor
@Suite struct TeamHomeRouterTests {
    @Test func openingTheHomeRemembersTheChatAndLeavingReturnsToIt() {
        let router = Router()
        router.selectedAgentID = "forge"
        router.select(mode: .files)
        router.showTeamHome()
        #expect(router.mode == .team)
        #expect(router.showsTeamHome)
        #expect(router.agentBeforeHome == "forge")
        #expect(router.selectedAgentID == nil, "agent commands have nothing to act on at the home")
        #expect(router.shownAgentID == nil)
        router.leaveTeamHome()
        #expect(!router.showsTeamHome)
        #expect(router.selectedAgentID == "forge")
        #expect(router.agentBeforeHome == nil)
    }

    @Test func showingTheHomeTwiceKeepsTheFirstChat() {
        let router = Router()
        router.selectedAgentID = "forge"
        router.shownAgentID = "forge"
        router.showTeamHome()
        router.showTeamHome()
        #expect(router.agentBeforeHome == "forge")
        router.leaveTeamHome()
        #expect(router.selectedAgentID == "forge")
    }

    @Test func choosingAnAgentLeavesTheHome() {
        let router = Router()
        router.showTeamHome()
        router.selectedAgentID = "scout"
        #expect(!router.showsTeamHome)
    }

    @Test func leavingWithoutTheHomeDoesNothing() {
        let router = Router()
        router.selectedAgentID = "forge"
        router.leaveTeamHome()
        #expect(router.selectedAgentID == "forge")
    }

    @Test func aServerChangeForgetsTheChatBeforeTheHome() {
        let router = Router()
        router.selectedAgentID = "forge"
        router.showTeamHome()
        router.dropPendingServerActions()
        #expect(router.agentBeforeHome == nil)
    }

    @Test func inBrowserModeBackAndForwardGoToThePageHistory() {
        let router = Router()
        var log: [String] = []
        router.select(mode: .browser)
        router.browserHistory = BrowserHistoryHandle(
            canBack: { true }, canForward: { false }, back: { log.append("back") }, forward: { log.append("forward") })
        #expect(router.canGoBack)
        #expect(!router.canGoForward)
        router.back()
        router.forward()
        #expect(log == ["back", "forward"])
        #expect(router.mode == .browser)
    }
}

@Suite struct TeamHomeLogicTests {
    @Test func theNewestComeFirstAndOnlySixAreKept() {
        let items = Array(1...9)
        let out = TeamHomeLogic.recent(items) { Int64($0) }
        #expect(out == [9, 8, 7, 6, 5, 4])
    }

    @Test func equalTimesKeepTheirOrder() {
        let out = TeamHomeLogic.recent(["a", "b", "c"], limit: 2) { _ in 5 }
        #expect(out == ["a", "b"])
    }

    @Test func fewerThanTheLimitAreAllShown() {
        #expect(TeamHomeLogic.recent([3, 1]) { Int64($0) } == [3, 1])
        #expect(TeamHomeLogic.recent([Int]()) { Int64($0) }.isEmpty)
    }
}
