#if os(macOS) && DEBUG
import AppKit
import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

extension ScreenWorkSuites {
    /// The main screens do no more work than they need: deterministic counts (bodies evaluated, cells made and
    /// reconfigured, rows measured) for one step of each, against a budget. Time is never measured here (no GPU on CI,
    /// noise): a change that makes a screen rebuild more fails before it is merged. Budgets are today's counts with a
    /// little room; a lower count is welcome (lower the budget with it).
    @MainActor @Suite(.serialized) struct WorkBudgetTests {
        static let probe = ProcessInfo.processInfo.environment["WORK_BUDGET_PRINT"] != nil

        // Where to look when a counter grows.
        static let list = "the thread's table: ThreadListView (Team/ThreadList.swift), the native rows (NativeRowViews.swift)"
        static let rows = "a SwiftUI row of the thread (ThreadRowViews.swift, MessageActions.swift, MessageBody.swift)"
        static let frame = "what the chat's frame reads (ThreadView.swift, ThreadHeader.swift, Composer.swift): a new read of the thread or the router"
        static let sidebar = "the team sidebar (TeamSidebar.swift): a new read of every agent's state"

        static func budget(_ counter: String, _ limit: Int, _ lookAt: String) -> WorkBudget {
            WorkBudget(counter: counter, limit: limit, lookAt: lookAt)
        }

        /// Records an issue for each counter over its budget, at the call. `WORK_BUDGET_PRINT=1` prints the counts.
        private func check(
            _ counts: [String: Int], _ budgets: [WorkBudget], _ scenario: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            if Self.probe { print("WORKBUDGET \(scenario): \(counts.sorted { $0.key < $1.key })") }
            for message in WorkBudget.excesses(counts, budgets, scenario: scenario) {
                Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
            }
        }

        @Test func mainScreensStayWithinTheirWork() async throws {
            let harness = WorkBudgetHarness()
            await harness.start()
            let router = harness.router
            let world = harness.world

            // The thread of 1500 rows on screen.
            router.select(mode: .team)
            router.selectedAgentID = PerfFixtures.threadAgentID
            await harness.settle(rounds: 60)
            let scroll = try #require(harness.threadScroll, "the thread's scroll view")

            // 1. Scrolling up 40 steps of 100 pt.
            let scrolled = await harness.count {
                for _ in 0..<40 {
                    PerfScroller.scroll(scroll, to: scroll.contentView.bounds.origin.y - 100)
                    await harness.settle(rounds: 1)
                }
            }
            // About 25 rows come into view: each is made and measured once, nothing else is rebuilt.
            check(scrolled, [
                Self.budget("ThreadList.viewFor", 32, Self.list), Self.budget("ThreadList.measure", 32, Self.list),
                Self.budget("ThreadList.nativeRowShown", 30, Self.list), Self.budget("ThreadList.swiftUIRowShown", 4, Self.list),
                Self.budget("ItemView", 8, Self.rows), Self.budget("MessageContainer", 8, Self.rows),
                Self.budget("MessageBody", 5, Self.rows), Self.budget("ThreadRow", 5, Self.rows),
                Self.budget("ThreadView", 2, Self.frame), Self.budget("Composer", 2, Self.frame),
                Self.budget("ThreadHeader", 2, Self.frame), Self.budget("TeamSidebar", 0, Self.sidebar),
                Self.budget("AgentRow", 0, Self.sidebar),
            ], "scroll the thread 4000 pt")

            // 2. Typing 20 letters in the composer (the text goes in as the field writes it).
            let typed = await harness.count {
                var text = ""
                for letter in "the quick brown fox " {
                    text.append(letter)
                    router.drafts[PerfFixtures.threadAgentID] = text
                    await harness.settle(rounds: 1)
                }
                router.drafts[PerfFixtures.threadAgentID] = nil
            }
            // Only the composer's field reads the text; the composer redraws once or twice (empty → not empty).
            check(typed, [
                Self.budget("Composer", 3, "the composer reads the draft (Composer.swift): only DraftFacts may change it"),
                Self.budget("ThreadView", 0, Self.frame), Self.budget("ThreadHeader", 0, Self.frame),
                Self.budget("TeamSidebar", 0, Self.sidebar), Self.budget("AgentRow", 0, Self.sidebar),
                Self.budget("ItemView", 0, Self.rows), Self.budget("ThreadList.viewFor", 0, Self.list),
                Self.budget("ThreadList.nativeRowShown", 0, Self.list),
            ], "type 20 letters")

            // 3. A reply streamed in 100 pieces into a chat on screen at its newest message. A chat just opened is at its
            // bottom by rule; the thread scrolled away above is not, and whether a scroll back down counts as "at the
            // bottom" depended on when its rows were measured (on a slow runner the new rows then counted as unseen
            // and redrew the frame). The turn starts and ends outside the step: its status changes are not the stream.
            let transport = world.primaryTransport
            let id = world.agentIDs[10]
            router.selectedAgentID = id
            await harness.settle(rounds: 30)
            await transport.emitEvent(
                agentID: id, kind: "turn.started", payload: ["turn_id": "budget-turn", "source": "user"],
                persisted: true)
            // The preview's interval is long here, so the count does not depend on how fast the machine runs: the
            // first piece writes it, the rest wait (StreamPreviewThrottle is tested on its own).
            let interval = AgentThreadState.streamPreviewInterval
            AgentThreadState.streamPreviewInterval = .seconds(60)
            defer { AgentThreadState.streamPreviewInterval = interval }
            let streamed = await harness.count {
                for index in 0..<100 {
                    await transport.emitEvent(
                        agentID: id, kind: "message.delta", payload: ["text": "word\(index) "], persisted: false)
                    await harness.settle(rounds: 1)
                }
            }
            // Only the streamed line is reconfigured and measured, once a piece or less (pieces that come together are
            // one); the chat's frame and the team list do not move.
            check(streamed, [
                Self.budget("ThreadList.nativeRowShown", 101, Self.list), Self.budget("ThreadList.measure", 101, Self.list),
                Self.budget("ThreadList.viewFor", 2, Self.list), Self.budget("ThreadList.swiftUIRowShown", 1, Self.list),
                Self.budget("ItemView", 1, Self.rows), Self.budget("ThreadView", 0, Self.frame),
                Self.budget("Composer", 0, Self.frame), Self.budget("ThreadHeader", 0, Self.frame),
                Self.budget("TeamSidebar", 0, Self.sidebar),
                Self.budget(
                    "AgentRow", 1,
                    "the sidebar's agent rows: what SidebarThreadFacts take from the thread; the streamed preview is written at most once per AgentThreadState.streamPreviewInterval"),
            ], "stream 100 pieces")
            await transport.emitEvent(
                agentID: id, kind: "message.assistant", payload: ["text": "done"], persisted: true)
            await transport.emitEvent(
                agentID: id, kind: "turn.completed", payload: ["turn_id": "budget-turn", "status": "ok"],
                persisted: true)
            await harness.settle(rounds: 30)

            // 4. Switching between agents: four new ones, then back to each (their lists are kept).
            let agents = Array(world.agentIDs.prefix(4))
            let switched = await harness.count {
                for agent in agents {
                    router.selectedAgentID = agent
                    await harness.settle(rounds: 6)
                }
            }
            // A new agent makes only the rows on screen; the sidebar and the frame redraw once per switch.
            check(switched, [
                Self.budget("ThreadList.newList", 4, Self.list), Self.budget("ThreadList.viewFor", 24, Self.list),
                Self.budget("ThreadList.measure", 24, Self.list), Self.budget("ThreadList.nativeRowShown", 24, Self.list),
                Self.budget("ThreadList.widthChange", 4, Self.list), Self.budget("ItemView", 3, Self.rows),
                Self.budget("ThreadView", 6, Self.frame), Self.budget("Composer", 6, Self.frame),
                Self.budget("ThreadHeader", 6, Self.frame), Self.budget("TeamSidebar", 6, Self.sidebar),
            ], "switch to 4 agents")
            let back = await harness.count {
                for agent in agents.reversed() {
                    router.selectedAgentID = agent
                    await harness.settle(rounds: 6)
                }
            }
            // Their lists are kept (ThreadListHost): nothing is made again.
            check(back, [
                Self.budget("ThreadList.newList", 0, "ThreadListHost keeps the last four agents' lists"),
                Self.budget("ThreadList.viewFor", 2, Self.list), Self.budget("ThreadList.measure", 2, Self.list),
                Self.budget("ThreadList.nativeRowShown", 2, Self.list), Self.budget("ThreadView", 4, Self.frame),
                Self.budget("Composer", 4, Self.frame), Self.budget("ThreadHeader", 4, Self.frame),
                Self.budget("TeamSidebar", 4, Self.sidebar),
            ], "back to the 4 kept agents")

            // 5. The agent's panel opened and closed 3 times.
            router.selectedAgentID = PerfFixtures.threadAgentID
            await harness.settle(rounds: 20)
            let panel = await harness.count {
                for _ in 0..<3 {
                    router.showInWorkbench(.details, agentID: PerfFixtures.threadAgentID)
                    await harness.settle(rounds: 10)
                    router.toggleWorkbench()
                    await harness.settle(rounds: 10)
                }
            }
            // The chat changes its width: the rows on screen are measured again, nothing is made again.
            check(panel, [
                Self.budget("ThreadList.viewFor", 12, Self.list), Self.budget("ThreadList.measure", 8, Self.list),
                // (The rows reconfigured during the move depend on its frames: not counted here.)
                Self.budget("ThreadList.widthChange", 7, "only the list on screen follows the width (ThreadListHost.show)"),
                Self.budget("ThreadView", 8, Self.frame), Self.budget("Composer", 8, Self.frame),
                Self.budget("ThreadHeader", 8, Self.frame), Self.budget("TeamSidebar", 0, Self.sidebar),
            ], "open and close the agent's panel 3 times")

            // 6. The Marketplace: a category opened and left, and a search typed.
            router.select(mode: .market)
            router.marketTab = .services
            await harness.settle(rounds: 80)
            let market = await harness.count {
                for name in router.marketCategories.prefix(2) {
                    router.marketFilter = .category(name)
                    await harness.settle(rounds: 6)
                    router.marketFilter = .all
                    await harness.settle(rounds: 6)
                }
            }
            // The header is not rebuilt (MarketHeader is Equatable); the shelves come back as they were left.
            check(market, [
                Self.budget("MarketHeader", 0, "MarketHeader (Market/MarketHeader.swift) is rebuilt with the page"),
                Self.budget("MarketShelf", 34, "the shelves (MarketShelfViews.swift, MarketView.scrollArea)"),
                Self.budget("MarketShelfArrows", 34, "the shelves' arrows (MarketShelfViews.swift)"),
            ], "open 2 Marketplace categories")

            await harness.stop()
        }
    }
}
#endif
