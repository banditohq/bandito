import BanditoDesign
import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

@Suite struct CrewOrderTests {
    @Test func leadComesFirstThenPinnedThenTheRest() {
        let ordered = CrewOrder.ordered(["a", "b", "c", "d", "e"], id: { $0 }, lead: "d", pinned: ["c", "a"])
        #expect(ordered == ["d", "a", "c", "b", "e"])
    }

    @Test func withoutALeadOrPinsTheOrderStays() {
        #expect(CrewOrder.ordered(["x", "y", "z"], id: { $0 }, lead: nil, pinned: []) == ["x", "y", "z"])
    }
}

@Suite struct CrewPinsTests {
    @Test func toggleAddsAndRemoves() {
        #expect(CrewPins.toggled("a", in: []) == ["a"])
        #expect(CrewPins.toggled("a", in: ["a", "b"]) == ["b"])
    }

    @Test func pinsAreKeptPerServer() {
        let defaults = UserDefaults(suiteName: "crew.tests.\(UUID().uuidString)")!
        let server = UUID()
        let other = UUID()
        CrewPins.save(["a"], serverID: server, defaults: defaults)
        #expect(CrewPins.load(server, defaults: defaults) == ["a"])
        #expect(CrewPins.load(other, defaults: defaults).isEmpty)
    }
}

@Suite struct CrewPreviewTests {
    @Test func collapsesWhitespaceAndDropsAnEmptyLine() {
        #expect(CrewPreview.line("  Hello\n\n  there \t you ") == "Hello there you")
        #expect(CrewPreview.line("  \n ") == nil)
        #expect(CrewPreview.line(nil) == nil)
    }

    @Test func markdownMarksAreLeftOut() {
        #expect(CrewPreview.line("The queue now **resends** a `msg`") == "The queue now resends a msg")
        let heading = CrewPreview.line("# Title\n\n- one\n- two")
        #expect(heading?.contains("#") == false)
        #expect(heading?.contains("\n") == false)
    }

    /// A cut in the middle of `**bold` or a code span leaves no stray marks at the word ends.
    @Test func aCutInsideEmphasisLeavesNoStars() {
        #expect(CrewPreview.line("Done, see **the logs and the") == "Done, see the logs and the")
        #expect(CrewPreview.line("Run `make` and _wait") == "Run make and wait")
    }

    @Test func emptyTextIsNoLine() {
        #expect(CrewPreview.line("") == nil)
        #expect(CrewPreview.line("   ") == nil)
    }
}

@Suite struct CrewMoodTests {
    @Test func aPausedAgentSleepsWhateverItDid() {
        #expect(AvatarMood.crew(status: .working, turnRunning: true, paused: true) == .sleeping)
    }

    @Test func waitingAndErrorsShowThrough() {
        #expect(AvatarMood.crew(status: .needsYou, turnRunning: false, paused: false) == .needsYou)
        #expect(AvatarMood.crew(status: .error, turnRunning: false, paused: false) == .error)
        #expect(AvatarMood.crew(status: .offline, turnRunning: false, paused: false) == .sleeping)
    }

    @Test func anIdleAgentWithATurnThinks() {
        #expect(AvatarMood.crew(status: .idle, turnRunning: true, paused: false) == .thinking)
        #expect(AvatarMood.crew(status: .idle, turnRunning: false, paused: false) == .idle)
        #expect(AvatarMood.crew(status: .working, turnRunning: false, paused: false) == .working)
    }
}

@Suite struct CrewLookTests {
    private func agent(avatar: AvatarSpec?) -> Agent {
        var agent = Agent(
            id: "look-1", name: "Forge", role: "Builder", runtime: .claude, cwd: "/tmp", createdAt: 0, updatedAt: 0,
            status: .idle)
        agent.avatar = avatar
        return agent
    }

    @Test func aSavedPaletteColorAndFaceAreUsed() {
        let look = CrewLook(agent: agent(avatar: AvatarSpec(color: "sky", face: "carets")))
        #expect(look.color == .sky)
        #expect(look.face == .carets)
        #expect(look.customHex == nil)
    }

    @Test func aCustomHexIsKeptAsTheTileColor() {
        let look = CrewLook(agent: agent(avatar: AvatarSpec(color: "#33aa66", face: "dots")))
        #expect(look.customHex == "#33AA66")
        #expect(AvatarHex.value("#33AA66") == 0x33AA66)
    }

    @Test func withNothingSavedTheNameDecides() {
        let look = CrewLook(agent: agent(avatar: nil))
        #expect(look.customHex == nil)
        #expect(look == CrewLook(agent: agent(avatar: nil)))
    }
}

/// The Crew shows two waiting cards; the rest is counted in one line.
@Suite struct CrewWaitingSplitTests {
    @Test func noneWaitingShowsNoCardAndNoLine() {
        let split = CrewWaitingSplit.split([String](), limit: 2)
        #expect(split.shown.isEmpty)
        #expect(split.more == 0)
    }

    @Test func twoWaitingShowTwoCardsAndNoLine() {
        let split = CrewWaitingSplit.split(["a", "b"], limit: 2)
        #expect(split.shown == ["a", "b"])
        #expect(split.more == 0)
    }

    @Test func threeWaitingShowTwoCardsAndOneMore() {
        let split = CrewWaitingSplit.split(["a", "b", "c"])
        #expect(split.shown == ["a", "b"])
        #expect(split.more == 1)
    }
}

@MainActor
@Suite struct CrewFactsTests {
    @Test func theDemoTeamShowsWhatEachAgentWaitsFor() async {
        let server = await IOSDemo.start()
        let rows = CrewFacts.build(server: server, pinned: [])
        #expect(rows.count == IOSDemo.team.count)
        #expect(rows.first { $0.name == "Forge" }?.waiting == .approval(title: "git push origin feat/ios-crew"))
        #expect(rows.first { $0.name == "Watch" }?.waiting == .answer(question: "The server disk is 81% full. Should I clear the cache?"))
        #expect(rows.first { $0.name == "Quill" }?.waiting == .form)
        #expect(rows.first { $0.name == "Scout" }?.waiting == nil)
        await server.disconnect()
    }

    @Test func aPinnedAgentIsMarkedAndMovedUp() async {
        let server = await IOSDemo.start()
        let scout = server.sortedAgents.first { $0.name == "Scout" }!.id
        let rows = CrewFacts.build(server: server, pinned: [scout])
        // The lead stays first; the pinned agent comes right after it.
        #expect(rows.first?.isLead == true)
        #expect(rows.dropFirst().first?.id == scout)
        #expect(rows.dropFirst().first?.isPinned == true)
        await server.disconnect()
    }

    @Test func theDemoTeamHasHistoryALeadAndOneUnreadReply() async {
        let server = await IOSDemo.start()
        let rows = CrewFacts.build(server: server, pinned: [])
        #expect(rows.first { $0.name == "Forge" }?.isLead == true)
        #expect(rows.filter(\.isLead).count == 1)
        #expect(rows.first { $0.name == "Scout" }?.unread == 1)
        #expect(rows.first { $0.name == "Forge" }?.unread == 0)
        #expect(rows.first { $0.name == "Scout" }?.preview == IOSDemo.unreadReply)
        #expect(rows.first { $0.name == "Watch" }?.preview == "The server disk is 81% full. Should I clear the cache?")
        #expect(rows.allSatisfy { $0.preview != nil })
        await server.disconnect()
    }

    /// An approval the daemon counts but whose row is not loaded is not in the Inbox, so the agent does not wait for it.
    @Test func anApprovalWithoutItsRowIsNotWaiting() async {
        let server = await IOSDemo.start(withTeam: false)
        let id = "waiting-unloaded"
        var agent = Agent(
            id: id, name: "Forge", role: "Builder", runtime: .claude, cwd: DemoDaemonFiles.projects,
            createdAt: 1, updatedAt: 1, status: .working)
        agent.pendingApprovalIds = ["approval-unloaded"]
        agent.reportsPendingApprovalIds = true
        server.installSyntheticAgent(agent, items: [])
        #expect(server.needsPerson(id))
        #expect(CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.waiting == nil)
        await server.disconnect()
    }

    /// A service the agent asks to connect is waiting for the person, as in the Inbox.
    @Test func aConnectRequestIsWaiting() async {
        let server = await IOSDemo.start(withTeam: false)
        let id = "waiting-connect"
        server.installSyntheticAgent(
            Agent(
                id: id, name: "Forge", role: "Builder", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: 1, updatedAt: 1, status: .working),
            items: [.connect(ConnectRow(requestId: "c1", service: "GitHub", ts: 1))])
        #expect(CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.waiting == .connect(service: "GitHub"))
        await server.disconnect()
    }

    /// An open form counts as waiting even when the agent is in error, not "needs you" (the Inbox lists it too).
    @Test func anOpenFormOnAnAgentInErrorIsWaiting() async {
        let server = await IOSDemo.start(withTeam: false)
        let id = "waiting-form"
        server.installSyntheticAgent(
            Agent(
                id: id, name: "Forge", role: "Builder", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: 1, updatedAt: 1, status: .error),
            items: [.form(FormRow(formId: "f1", spec: FormSpec(title: "Deploy?", fields: []), ts: 1))])
        #expect(CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.waiting == .form)
        await server.disconnect()
    }

    /// An agent that needs the person with no approval or form asks its question: the card shows the text, Markdown-free.
    @Test func anAgentThatNeedsYouWaitsWithItsQuestion() async {
        let server = await IOSDemo.start(withTeam: false)
        let id = "waiting-question"
        server.installSyntheticAgent(
            Agent(
                id: id, name: "Forge", role: "Builder", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: 1, updatedAt: 1, status: .needsYou),
            items: [.assistant(id: "s1", text: "Should I push **main**?", ts: 1)])
        #expect(CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.waiting
            == .answer(question: "Should I push main?"))
        await server.disconnect()
    }

    @Test func anIdleAgentWithNothingPendingWaitsForNothing() async {
        let server = await IOSDemo.start(withTeam: false)
        let id = "waiting-none"
        server.installSyntheticAgent(
            Agent(
                id: id, name: "Forge", role: "Builder", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: 1, updatedAt: 1, status: .idle),
            items: [.assistant(id: "s1", text: "Done.", ts: 1)])
        #expect(CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.waiting == nil)
        await server.disconnect()
    }

    @Test func aServerWithoutAgentsHasNoRows() async {
        let server = await IOSDemo.start(withTeam: false)
        #expect(CrewFacts.build(server: server, pinned: []).isEmpty)
        await server.disconnect()
    }

    @Test func theLaunchArgumentForAnEmptyDemoIsRecognised() {
        #expect(IOSDemo.isRequested(in: ["Bandito", "-demo-empty"]))
        #expect(IOSDemo.isEmptyRequested(in: ["Bandito", "-demo-empty"]))
        #expect(!IOSDemo.isEmptyRequested(in: ["Bandito", "-demo"]))
    }

    @Test func theDemoHasTwoServers() async {
        let servers = await IOSDemo.startServers()
        #expect(servers.count == 2)
        #expect(servers.first?.agents.count == IOSDemo.team.count)
        for server in servers { await server.disconnect() }
    }

    /// A widget or Spotlight link on a cold start names an agent the servers have not listed yet: it waits for it.
    @MainActor @Test func aFocusWaitsForItsAgentToBeListed() async throws {
        let server = await IOSDemo.start()
        let agentID = try #require(server.agents.first?.id)
        let focus = CrewFocus(serverID: server.id, agentID: agentID, request: UUID())
        #expect(focus.isListed(in: []) == false)
        #expect(focus.isListed(in: [server]))
        #expect(CrewFocus(serverID: server.id, agentID: "no-such", request: UUID()).isListed(in: [server]) == false)
        await server.disconnect()
    }
}

/// What a running turn does now, on the Crew row and in the chat header: the newest unfinished tool decides, and the
/// start of the turn is the timer's.
@MainActor
@Suite struct CrewWorkingTests {
    private func waitUntil(_ limit: Int = 100, _ done: () -> Bool) async {
        var waited = 0
        while !done(), waited < limit {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
    }

    private func installAgent(_ server: ServerModel, id: String) {
        server.installSyntheticAgent(
            Agent(
                id: id, name: "Forge", role: "Builder", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: 1, updatedAt: 1, status: .working),
            items: [])
    }

    @Test func aRunningCommandOfATurnReadsAsRunningACommand() async {
        let server = await IOSDemo.start(withTeam: false)
        let id = "working-command"
        installAgent(server, id: id)
        server.apply(Event(seq: 0, agentId: id, ts: 1_700_000_000_000, body: .turnStarted(turnId: "t1", source: .user)))
        server.apply(Event(
            seq: 0, agentId: id, ts: 1_700_000_001_000,
            body: .toolCall(callId: "c1", tool: "Bash", title: "swift test", input: .null)))
        await waitUntil { CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.working != nil }
        let working = CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.working
        #expect(working?.activity == .command)
        #expect(working?.since == CrewTime.date(ms: 1_700_000_000_000))
        await server.disconnect()
    }

    @Test func aTurnWithoutAStartOrWithNoTurnHasNoWorking() async {
        let server = await IOSDemo.start(withTeam: false)
        let id = "working-none"
        installAgent(server, id: id)
        #expect(CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.working == nil)
        server.apply(Event(seq: 0, agentId: id, ts: 1_700_000_000_000, body: .turnStarted(turnId: "t1", source: .user)))
        await waitUntil { server.threadSummary(for: id).turnRunning }
        #expect(CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.working?.activity == .thinking)
        server.apply(Event(
            seq: 0, agentId: id, ts: 1_700_000_002_000,
            body: .turnCompleted(turnId: "t1", status: .ok, usage: nil, costUsd: nil)))
        await waitUntil { CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.working == nil }
        #expect(CrewFacts.build(server: server, pinned: []).first { $0.id == id }?.working == nil)
        await server.disconnect()
    }
}
