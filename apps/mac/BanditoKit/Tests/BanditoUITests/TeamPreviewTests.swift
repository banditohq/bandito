import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct TeamPreviewTests {
    private func agent(_ id: String, last: LastMessage? = nil, lastTurnAt: Int64? = nil, updatedAt: Int64 = 0) -> Agent {
        Agent(
            id: id, name: id, runtime: .claude, cwd: "/x", updatedAt: updatedAt, lastTurnAt: lastTurnAt,
            lastMessage: last)
    }

    private func thread(_ items: [ThreadItem], status: AgentStatus = .idle) -> AgentThread {
        var t = AgentThread()
        t.items = items
        t.status = status
        return t
    }

    private let pending = ApprovalRow(
        approvalId: "p", tool: "shell", title: "Run rm", command: nil, diff: nil, reason: "", state: .pending)

    // MARK: text

    @Test func loadedThreadWinsOverTheDaemonsLastMessage() {
        let a = agent("a", last: LastMessage(role: "assistant", text: "from daemon", ts: 1))
        let t = thread([.assistant(id: "x", text: "from thread", ts: 2)])
        #expect(AgentPreview.text(thread: t, agent: a) == "from thread")
    }

    @Test func threadWithoutMessagesFallsBackToTheDaemonsLastMessage() {
        let a = agent("a", last: LastMessage(role: "user", text: "from daemon", ts: 1))
        let onlyTools = thread([.note(id: "n", text: "Chapter 2", kind: .info, ts: 3)])
        #expect(AgentPreview.text(thread: onlyTools, agent: a) == "from daemon")
        #expect(AgentPreview.text(thread: AgentThread(), agent: a) == "from daemon", "not loaded yet")
    }

    @Test func approvalTitleIsNotThePreviewText() {
        let a = agent("a")
        let waiting = thread([.approval(pending)], status: .needsYou)
        #expect(AgentPreview.text(thread: waiting, agent: a) == nil)
    }

    @Test func noMessageAnywhereGivesNoText() {
        #expect(AgentPreview.text(thread: AgentThread(), agent: agent("a")) == nil)
    }

    // MARK: time

    @Test func rowTimeIsTheNewerOfThreadAndDaemonMessage() {
        let t = thread([.assistant(id: "x", text: "hi", ts: 100)])
        let newerDaemon = agent("a", last: LastMessage(role: "assistant", text: "", ts: 200))
        #expect(AgentPreview.timestamp(thread: t, agent: newerDaemon) == 200)

        let olderDaemon = agent("a", last: LastMessage(role: "assistant", text: "", ts: 50))
        #expect(AgentPreview.timestamp(thread: t, agent: olderDaemon) == 100)
    }

    @Test func rowTimeFallsBackToTheLastTurnThenTheUpdate() {
        #expect(AgentPreview.timestamp(thread: AgentThread(), agent: agent("a", lastTurnAt: 7, updatedAt: 9)) == 7)
        #expect(AgentPreview.timestamp(thread: AgentThread(), agent: agent("a", updatedAt: 9)) == 9)
    }

    // MARK: sidebar order

    @Test func pinnedTilesComeFirstThenThoseWhoNeedAPerson() {
        let agents = ["a", "b", "c", "d", "e"].map { agent($0) }
        let order = TeamSidebarOrder.ids(agents: agents, pinned: ["d"]) { $0 == "c" }
        #expect(order == ["d", "c", "a", "b", "e"])
    }

    @Test func eightPinnedAgentsAreTilesAtTheTop() {
        #expect(TeamSidebarOrder.pinnedTiles == 8)
        let agents = ["a", "b", "c"].map { agent($0) }
        let order = TeamSidebarOrder.ids(agents: agents, pinned: ["a", "b", "c"]) { _ in false }
        #expect(order == ["a", "b", "c"])
        let withWaiting = TeamSidebarOrder.ids(agents: agents, pinned: ["a", "b", "c"]) { $0 == "c" }
        #expect(withWaiting == ["a", "b", "c"])
    }

    @Test func firstAgentIsTheFirstInSidebarOrder() {
        let agents = ["a", "b"].map { agent($0) }
        #expect(TeamSidebarOrder.ids(agents: agents, pinned: ["b"]) { _ in false }.first == "b")
        #expect(TeamSidebarOrder.ids(agents: agents, pinned: []) { _ in false }.first == "a")
        #expect(TeamSidebarOrder.ids(agents: [], pinned: []) { _ in false }.isEmpty)
    }

    // MARK: the agent on screen does not move

    /// Nothing is chosen, so the first agent in sidebar order is shown. It is kept as the chosen one, so when another
    /// agent needs a person and moves to the top, the one on screen stays where it is.
    @Test func shownAgentStaysPutWhenAnotherAgentNeedsYou() {
        let agents = ["a", "b"].map { agent($0) }
        let before = TeamSidebarOrder.ids(agents: agents, pinned: []) { _ in false }
        let shown = TeamSelection.resolve(selected: nil, remembered: nil, order: before)
        #expect(shown == "a")
        let kept = TeamSelection.keptChoice(shown: shown)

        let after = TeamSidebarOrder.ids(agents: agents, pinned: []) { $0 == "b" }
        #expect(after.first == "b", "the sidebar moved b to the top")
        #expect(TeamSelection.resolve(selected: kept, remembered: nil, order: after) == "a", "the screen did not")
        #expect(TeamSelection.resolve(selected: nil, remembered: nil, order: after) == "b", "without keeping it would jump")
    }

    /// A chosen agent that is no longer on this server (`gone` is not in the order) falls back to the first in order.
    @Test func unknownChoiceFallsBackToTheFirstInOrder() {
        #expect(TeamSelection.resolve(selected: "gone", remembered: nil, order: ["b", "c"]) == "b")
        #expect(TeamSelection.resolve(selected: "gone", remembered: "c", order: ["b", "c"]) == "c")
    }

    /// Nothing shown yields nothing to keep: the choice stays empty and the first agent is picked again later.
    @Test func keptChoiceOfNothingIsNothing() {
        #expect(TeamSelection.keptChoice(shown: nil) == nil)
    }
}
