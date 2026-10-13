import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// The rows of the chat: what a thread becomes, and what the screen has beyond it (the queue, the working row, the card).
@MainActor
@Suite struct ChatRowsTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let now = Date(timeIntervalSince1970: 1_792_000_000)

    func input(
        _ items: [ThreadItem], queued: [QueuedSend] = [], running: Bool = false, changes: ChatChangesSummary? = nil,
        expanded: Set<String> = []
    ) -> ChatRowInput {
        var thread = AgentThread()
        thread.items = items
        thread.turnRunning = running
        return ChatRowInput(
            thread: thread, agentName: "Forge", primaryRuntime: "claude", queued: queued, expanded: expanded, changes: changes,
            calendar: Self.calendar, now: Self.now)
    }

    var ts: Int64 { Int64(Self.now.timeIntervalSince1970 * 1000) }

    func tool(_ n: Int, ok: Bool? = true) -> ThreadItem {
        .tool(ToolRow(callId: "c\(n)", tool: "bash", title: "cmd \(n)", ok: ok))
    }

    @Test func sevenCommandsAreOneFoldedRow() throws {
        let rows = ChatRowBuilder.build(input((1...7).map { tool($0) }))
        let groups = rows.compactMap { row -> ChatToolGroup? in
            if case .tools(let group) = row.content { return group }
            return nil
        }
        #expect(groups.count == 1)
        #expect(groups[0].tools.count == 7)
        #expect(groups[0].status == .done)
        #expect(!groups[0].open)
        // Opening it changes the row's version, so its cell is set up again.
        let key = try #require(rows.first { if case .tools = $0.content { return true } else { return false } }?.id)
        let opened = ChatRowBuilder.build(input((1...7).map { tool($0) }, expanded: [key]))
        let before = rows.first { $0.id == key }
        let after = opened.first { $0.id == key }
        #expect(before?.version != after?.version)
    }

    @Test func aRunningCommandMakesTheGroupRunning() {
        let rows = ChatRowBuilder.build(input([tool(1), tool(2, ok: nil)]))
        guard case .tools(let group)? = rows.first?.content else {
            Issue.record("no group")
            return
        }
        #expect(group.status == .running)
    }

    @Test func messagesKeepTheirSenderAndTheTimeIsUnderTheLastOfAGroup() {
        let items: [ThreadItem] = [
            .user(id: "s1", text: "hi", source: .user, from: nil, ts: ts),
            .user(id: "s2", text: "again", source: .user, from: nil, ts: ts + 1000),
            .assistant(id: "s3", text: "hello", ts: ts + 2000),
        ]
        let rows = ChatRowBuilder.build(input(items))
        let messages = rows.compactMap { row -> ChatMessage? in
            if case .message(let message) = row.content { return message }
            return nil
        }
        #expect(messages.map(\.sender) == [.me, .me, .agent])
        #expect(messages.map(\.showsTime) == [false, true, true])
        #expect(messages.map(\.tail) == [false, true, true])
    }

    @Test func aQueuedMessageIsShownWaitingAndGoesWhenItsEventComes() {
        let item = QueuedSend(serverID: UUID(), agentID: "a", text: "later", createdAt: ts)
        let rows = ChatRowBuilder.build(input([], queued: [item]))
        guard case .message(let message)? = rows.last?.content else {
            Issue.record("no message")
            return
        }
        #expect(message.caption == .waitingForConnection)
        #expect(message.sender == .me)
        // The daemon answered and its event came: the pending row is not shown twice.
        var sent = item
        sent.state = .sent
        let echoed = ChatRowBuilder.build(input([.user(id: "s1", text: "later", source: .user, from: nil, ts: ts)], queued: [sent]))
        let messageIDs = echoed.filter { if case .message = $0.content { return true } else { return false } }.map(\.id)
        #expect(messageIDs == ["s1"])
    }

    @Test func aRefusedMessageCanBeTriedAgain() {
        var item = QueuedSend(serverID: UUID(), agentID: "a", text: "no", createdAt: ts)
        item.state = .failed
        let rows = ChatRowBuilder.build(input([], queued: [item]))
        guard case .message(let message)? = rows.last?.content else {
            Issue.record("no message")
            return
        }
        #expect(message.caption == .notSent(id: item.id, why: nil))
    }

    @Test func theWorkingRowShowsWhileATurnRunsAndYieldsToTheStream() {
        let running = ChatRowBuilder.build(input([.user(id: "s1", text: "go", source: .user, from: nil, ts: ts)], running: true))
        #expect(running.last?.id == "working")
        let streaming = ChatRowBuilder.build(
            input([.user(id: "s1", text: "go", source: .user, from: nil, ts: ts), .streaming(text: "Hel")], running: true))
        #expect(!streaming.contains { $0.id == "working" })
        #expect(streaming.last?.id == "streaming")
    }

    @Test func theChangesCardComesWhenTheTurnIsOver() {
        let summary = ChatChangesSummary(files: 12, additions: 240, deletions: 30)
        let idle = ChatRowBuilder.build(input([.assistant(id: "s1", text: "done", ts: ts)], changes: summary))
        #expect(idle.last?.id == "changes")
        #expect(summary.line.contains("+240"))
        let busy = ChatRowBuilder.build(input([.assistant(id: "s1", text: "done", ts: ts)], running: true, changes: summary))
        #expect(!busy.contains { $0.id == "changes" })
    }

    @Test func requestsAreCardsWhileTheyWaitAndLinesAfter() {
        let pending = ApprovalRow(
            approvalId: "a1", tool: "bash", title: "swift test", command: "swift test", diff: nil, reason: "risky: git push",
            state: .pending)
        var answered = pending
        answered.state = .approved(by: .user, remember: false)
        let waiting = ChatRowBuilder.build(input([.approval(pending)]))
        #expect(waiting.first?.content.isHosted == true)
        let done = ChatRowBuilder.build(input([.approval(answered)]))
        guard case .line(let line)? = done.first?.content else {
            Issue.record("no line")
            return
        }
        #expect(line.text.hasSuffix("swift test"))
        #expect(!(done.first?.content.isHosted ?? true))
    }

    @Test func aScheduledRunIsALineThatOpensItsPrompt() {
        let run = ScheduleRun(id: "r1", name: "Nightly", firedAt: ts)
        let item = ThreadItem.scheduleRun(id: "s5", run: run, prompt: "Check the disk", ts: ts)
        let closed = ChatRowBuilder.build(input([item]))
        guard case .line(let line)? = closed.last?.content else {
            Issue.record("no line")
            return
        }
        #expect(line.fold?.detail == "Check the disk")
        #expect(line.fold?.open == false)
        let opened = ChatRowBuilder.build(input([item], expanded: [ScheduleRunLine.runKey("s5")]))
        guard case .line(let openLine)? = opened.last?.content else {
            Issue.record("no line")
            return
        }
        #expect(openLine.fold?.open == true)
    }

    @Test func aStreamChangesOnlyItsOwnRowsVersion() {
        let base: [ThreadItem] = [.assistant(id: "s1", text: "one", ts: ts), .assistant(id: "s2", text: "two", ts: ts)]
        let a = ChatRowBuilder.build(input(base + [.streaming(text: "He")]))
        let b = ChatRowBuilder.build(input(base + [.streaming(text: "Hello")]))
        #expect(a.count == b.count)
        let changed = zip(a, b).filter { $0.version != $1.version }.map { $0.0.id }
        #expect(changed == ["streaming"])
    }

    @Test func aDayDividerSaysTodayAndYesterday() {
        let items: [ThreadItem] = [
            .assistant(id: "s1", text: "old", ts: ts - 24 * 3_600_000),
            .assistant(id: "s2", text: "new", ts: ts),
        ]
        let rows = ChatRowBuilder.build(input(items))
        let days = rows.compactMap { row -> String? in
            if case .day(let text) = row.content { return text }
            return nil
        }
        #expect(days.count == 2)
        #expect(days[0] != days[1])
    }

    @Test func rowsWithTheSameIdGetIdsOfTheirOwnThatStayTheSame() {
        // Two groups of commands whose first call has no id, two days out of order, two messages of one id.
        let items: [ThreadItem] = [
            .tool(ToolRow(callId: "", tool: "bash", title: "a", ok: true)),
            .assistant(id: "s1", text: "one", ts: ts),
            .tool(ToolRow(callId: "", tool: "bash", title: "b", ok: true)),
            .assistant(id: "s1", text: "again", ts: ts - 3 * 86_400_000),
            .assistant(id: "s2", text: "later", ts: ts),
            .assistant(id: "s3", text: "earlier", ts: ts - 3 * 86_400_000),
        ]
        let first = ChatRowBuilder.build(input(items)).map(\.id)
        let second = ChatRowBuilder.build(input(items)).map(\.id)
        #expect(Set(first).count == first.count, "ids: \(first)")
        #expect(first == second)
        #expect(first.contains("tools-#2") && first.contains("s1#2"))
    }

    @Test func aGroupOfCommandsWithADoubledIdOpensWithItsOwnKey() throws {
        let items: [ThreadItem] = [
            .tool(ToolRow(callId: "", tool: "bash", title: "a", ok: true)),
            .assistant(id: "s1", text: "between", ts: ts),
            .tool(ToolRow(callId: "", tool: "bash", title: "b", ok: true)),
        ]
        let rows = ChatRowBuilder.build(input(items, expanded: ["tools-#2"]))
        let open = rows.compactMap { row -> Bool? in
            if case .tools(let group) = row.content { return group.open }
            return nil
        }
        #expect(open == [false, true])
    }

    @Test func anUncertainMessageAsksThePersonAndAKeyFailureSaysSo() {
        var uncertain = QueuedSend(serverID: UUID(), agentID: "a", text: "maybe", createdAt: ts)
        uncertain.state = .uncertain
        var failed = QueuedSend(serverID: UUID(), agentID: "a", text: "key", createdAt: ts + 1)
        failed.state = .failed
        failed.failureKind = .key
        let rows = ChatRowBuilder.build(input([], queued: [uncertain, failed]))
        let captions = rows.compactMap { row -> ChatMessage.Caption? in
            if case .message(let message) = row.content { return message.caption }
            return nil
        }
        #expect(captions == [.uncertain(id: uncertain.id), .notSent(id: failed.id, why: .key)])
    }
}
