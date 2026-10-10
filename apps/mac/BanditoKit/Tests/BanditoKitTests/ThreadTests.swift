import Foundation
import Testing

@testable import BanditoKit

@Suite struct ThreadTests {
    var seq: Int64 = 0

    mutating func ev(_ body: EventBody, live: Bool = false) -> Event {
        if !live { seq += 1 }
        return Event(seq: live ? 0 : seq, agentId: "a", ts: 1_000 + seq, body: body)
    }

    @Test mutating func fullTurnWithApproval() {
        var t = AgentThread()
        t.apply(ev(.turnStarted(turnId: "t", source: .user)))
        t.apply(ev(.messageUser(text: "push it", source: .user, fromAgent: nil)))
        t.apply(ev(.agentStatus(status: .working, detail: nil)))
        t.apply(ev(.messageDelta(text: "On "), live: true))
        t.apply(ev(.messageDelta(text: "it"), live: true))
        #expect(t.items.last == .streaming(text: "On it"))
        t.apply(ev(.toolCall(callId: "c1", tool: "Bash", title: "git push", input: .null)))
        // Text streamed so far is kept as an assistant message instead of being thrown away.
        #expect(t.items.count == 3)
        guard case .assistant(_, "On it", _) = t.items[1] else { Issue.record("expected finalized stream"); return }
        t.apply(ev(.approvalRequested(approvalId: "ap", callId: "c1", tool: "Bash", title: "git push", command: "git push", diff: nil, reason: "risky: git push*")))
        t.apply(ev(.agentStatus(status: .needsYou, detail: nil)))
        #expect(t.status == .needsYou)
        #expect(t.pendingApprovals.map(\.approvalId) == ["ap"])
        #expect(t.preview == "git push")
        t.apply(ev(.approvalResolved(approvalId: "ap", decision: .allow, by: .user, remember: true)))
        #expect(t.pendingApprovals.isEmpty)
        t.apply(ev(.toolResult(callId: "c1", ok: true, output: "done")))
        t.apply(ev(.messageAssistant(text: "Pushed.")))
        t.apply(ev(.turnCompleted(turnId: "t", status: .ok, usage: nil, costUsd: nil)))
        t.apply(ev(.agentStatus(status: .idle, detail: nil)))
        #expect(!t.turnRunning)
        #expect(t.preview == "Pushed.")
        guard case .tool(let row) = t.items[2] else { Issue.record("expected tool row"); return }
        #expect(row.ok == true && row.output == "done")
        guard case .approval(let a) = t.items[3] else { Issue.record("expected approval row"); return }
        #expect(a.state == .approved(by: .user, remember: true))
        #expect(t.lastSeq == seq)
    }

    @Test mutating func withdrawnApprovalLeavesThePendingListAsAQuietLine() {
        var t = AgentThread()
        t.apply(ev(.approvalRequested(approvalId: "ap", callId: "c1", tool: "Bash", title: "rm x", command: "rm x", diff: nil, reason: "risky: rm")))
        #expect(t.pendingApprovals.map(\.approvalId) == ["ap"])
        // The CLI took the request back: nobody decided it, so the card is no longer pending.
        t.apply(ev(.approvalWithdrawn(approvalId: "ap")))
        #expect(t.pendingApprovals.isEmpty)
        guard case .approval(let row)? = t.items.last else { Issue.record("expected approval row"); return }
        #expect(row.state == .withdrawn)
    }

    @Test mutating func replayedEventsAreIgnored() {
        var t = AgentThread()
        let e = ev(.messageAssistant(text: "hi"))
        t.apply(e)
        t.apply(e)
        #expect(t.items.count == 1)
    }

    @Test mutating func crewAndScheduleGetNotes() {
        var t = AgentThread()
        t.apply(ev(.messageUser(text: "review pls", source: .crew, fromAgent: "Scout")))
        t.apply(ev(.messageUser(text: "audit", source: .schedule, fromAgent: nil)))
        let notes = t.items.compactMap { if case .note(_, let text, let kind, _) = $0 { return "\(kind.rawValue):\(text)" }; return nil }
        #expect(notes == ["crew:Message from Scout", "schedule:Scheduled run"])
    }

    @Test mutating func interruptedTurnKeepsPartialText() {
        var t = AgentThread()
        t.apply(ev(.messageDelta(text: "Half"), live: true))
        t.apply(ev(.turnCompleted(turnId: "t", status: .interrupted, usage: nil, costUsd: nil)))
        guard case .assistant(_, let text, _) = t.items[0] else { Issue.record("expected assistant"); return }
        #expect(text == "Half")
        guard case .note(_, "Stopped", .info, _) = t.items[1] else { Issue.record("expected stopped note"); return }
    }

    @Test mutating func errorsAreNotes() {
        var t = AgentThread()
        t.apply(ev(.error(message: "could not start the agent: runtime codex is not available")))
        guard case .note(_, let text, .error, _) = t.items[0] else { Issue.record("expected error note"); return }
        #expect(text.contains("codex"))
    }

    @Test mutating func systemTurnIsOnlyALine() {
        var t = AgentThread()
        t.apply(ev(.messageUser(text: "Update your memory files.", source: .system, fromAgent: nil)))
        #expect(t.items.count == 1)
        guard case .note(_, "Saving memory before a new chapter", .info, _) = t.items[0] else {
            Issue.record("expected info note, got \(t.items)")
            return
        }
    }

    /// The bug found live: the person wrote while the agent saved its memory, the message was not shown, and the
    /// counter ran from the last message shown (hours ago).
    @Test mutating func messageSentDuringTheMemorySaveShowsAtOnceAndMovesBelowTheChapter() {
        var t = AgentThread()
        t.apply(ev(.messageUser(text: "old question", source: .user, fromAgent: nil)))
        t.apply(ev(.turnCompleted(turnId: "t0", status: .ok, usage: nil, costUsd: nil)))
        // The memory save begins; the person writes meanwhile and the daemon shows the message at once, queued.
        t.apply(ev(.turnStarted(turnId: "w", source: .system)))
        t.apply(ev(.messageUser(text: "Update your memory files.", source: .system, fromAgent: nil)))
        t.apply(ev(.messageUser(text: "Which tasks do I have?", source: .user, fromAgent: nil, queued: true)))
        let queuedSeq = seq
        #expect(t.waitingSeqs == [queuedSeq])
        #expect(t.items.contains { if case .user(_, "Which tasks do I have?", _, _, _, _) = $0 { true } else { false } })

        t.apply(ev(.turnCompleted(turnId: "w", status: .ok, usage: nil, costUsd: nil)))
        t.apply(ev(.sessionRotated(chapter: 2, reason: "context", contextTokens: 130_000)))
        // Below the divider, where the agent reads it, and only once.
        let kinds = t.items.map { item -> String in
            switch item {
            case .chapter: "chapter"
            case .user(_, let text, _, _, _, _): "user:\(text)"
            default: "other"
            }
        }
        #expect(kinds.filter { $0 == "user:Which tasks do I have?" }.count == 1)
        #expect(kinds.suffix(2) == ["chapter", "user:Which tasks do I have?"])

        // Its turn begins: no longer waiting, and no second copy.
        t.apply(ev(.turnStarted(turnId: "t1", source: .user, messageSeq: queuedSeq)))
        #expect(t.waitingSeqs.isEmpty)
        #expect(t.items.filter { if case .user(_, "Which tasks do I have?", _, _, _, _) = $0 { true } else { false } }.count == 1)
    }

    @Test mutating func messageQueuedBehindARunningTurnWaitsUntilItsTurnNamesIt() {
        var t = AgentThread()
        t.apply(ev(.turnStarted(turnId: "a", source: .user)))
        t.apply(ev(.messageUser(text: "first", source: .user, fromAgent: nil)))
        t.apply(ev(.messageUser(text: "second", source: .user, fromAgent: nil, queued: true)))
        let second = seq
        #expect(t.waitingSeqs == [second])
        // The first turn ends and the second begins: the order of the items did not change.
        t.apply(ev(.turnCompleted(turnId: "a", status: .ok, usage: nil, costUsd: nil)))
        t.apply(ev(.turnStarted(turnId: "b", source: .user, messageSeq: second)))
        #expect(t.waitingSeqs.isEmpty)
        #expect(t.items.map(\.id).count == 2)
    }

    /// Merging a page of history with live events must not bring a started message back to the queue.
    @Test mutating func aStartedMessageStaysStartedAfterAMerge() {
        var live = AgentThread()
        live.apply(ev(.messageUser(text: "q", source: .user, fromAgent: nil, queued: true)))
        let q = seq
        live.apply(ev(.turnStarted(turnId: "b", source: .user, messageSeq: q)))
        var page = AgentThread()
        page.apply(Event(seq: q, agentId: "a", ts: 1, body: .messageUser(text: "q", source: .user, fromAgent: nil, queued: true)))
        #expect(page.waitingSeqs == [q])
        page.mergeMessageMeta(from: live)
        #expect(page.waitingSeqs.isEmpty)
    }

    /// The counter counts from the start of the running turn, not from the newest message shown.
    @Test mutating func turnStartIsTheTurnNotTheLastMessage() {
        var t = AgentThread()
        t.apply(Event(seq: 1, agentId: "a", ts: 1_000, body: .messageUser(text: "hi", source: .user, fromAgent: nil)))
        t.apply(Event(seq: 2, agentId: "a", ts: 1_001, body: .turnCompleted(turnId: "t", status: .ok, usage: nil, costUsd: nil)))
        #expect(t.turnStartedAt == nil)
        // Hours later the memory save runs.
        t.apply(Event(seq: 3, agentId: "a", ts: 13_000_000, body: .turnStarted(turnId: "w", source: .system)))
        #expect(t.turnStartedAt == 13_000_000)
        t.apply(Event(seq: 4, agentId: "a", ts: 13_050_000, body: .turnCompleted(turnId: "w", status: .ok, usage: nil, costUsd: nil)))
        #expect(t.turnStartedAt == nil)
        t.apply(Event(seq: 5, agentId: "a", ts: 13_060_000, body: .turnStarted(turnId: "t2", source: .user, messageSeq: nil)))
        #expect(t.turnStartedAt == 13_060_000)
    }

    @Test func queuedFlagsDecodeFromTheWire() throws {
        let message = Data(
            #"{"seq":5,"agent_id":"a","ts":1,"kind":"message.user","payload":{"text":"x","source":"user","queued":true}}"#.utf8)
        let plain = Data(#"{"seq":6,"agent_id":"a","ts":1,"kind":"message.user","payload":{"text":"x","source":"user"}}"#.utf8)
        let turn = Data(
            #"{"seq":7,"agent_id":"a","ts":1,"kind":"turn.started","payload":{"turn_id":"t","source":"user","message_seq":5}}"#.utf8)
        guard case .messageUser(_, _, _, _, _, let queued) = try RPCClient.decoder.decode(Event.self, from: message).body,
            case .messageUser(_, _, _, _, _, let notQueued) = try RPCClient.decoder.decode(Event.self, from: plain).body,
            case .turnStarted(_, _, let messageSeq) = try RPCClient.decoder.decode(Event.self, from: turn).body
        else {
            Issue.record("unexpected bodies")
            return
        }
        #expect(queued && !notQueued)
        #expect(messageSeq == 5)
    }

    @Test mutating func sessionRotatedIsANote() {
        var t = AgentThread()
        t.apply(ev(.sessionRotated(chapter: 2, reason: "smart", contextTokens: 120_400)))
        guard case .chapter(_, 2, true, _) = t.items[0] else {
            Issue.record("expected chapter item, got \(t.items)")
            return
        }
    }

    @Test mutating func chapterWhoseMemorySaveFailedIsMarkedUnsaved() {
        var t = AgentThread()
        t.apply(ev(.messageUser(text: "Update your memory files.", source: .system, fromAgent: nil)))
        t.apply(ev(.turnCompleted(turnId: "w", status: .error, usage: nil, costUsd: nil)))
        t.apply(ev(.sessionRotated(chapter: 2, reason: "context", contextTokens: 130_000)))
        guard case .chapter(_, 2, false, _) = t.items.last else {
            Issue.record("expected unsaved chapter, got \(t.items)")
            return
        }
    }

    @Test mutating func interruptedMemorySaveIsMarkedUnsaved() {
        var t = AgentThread()
        t.apply(ev(.messageUser(text: "Update your memory files.", source: .system, fromAgent: nil)))
        t.apply(ev(.turnCompleted(turnId: "w", status: .interrupted, usage: nil, costUsd: nil)))
        t.apply(ev(.sessionRotated(chapter: 2, reason: "context", contextTokens: 130_000)))
        guard case .chapter(_, 2, false, _) = t.items.last else {
            Issue.record("an interrupted memory save must leave the chapter unsaved, got \(t.items)")
            return
        }
    }

    @Test mutating func chapterWhoseMemorySaveSucceededIsSaved() {
        var t = AgentThread()
        t.apply(ev(.messageUser(text: "Update your memory files.", source: .system, fromAgent: nil)))
        t.apply(ev(.turnCompleted(turnId: "w", status: .ok, usage: nil, costUsd: nil)))
        t.apply(ev(.sessionRotated(chapter: 2, reason: "context", contextTokens: 130_000)))
        guard case .chapter(_, 2, true, _) = t.items.last else {
            Issue.record("expected saved chapter item, got \(t.items)")
            return
        }
    }

    @Test mutating func chapterClosedWithoutWrapUpIsMarkedUnsaved() {
        var t = AgentThread()
        t.apply(ev(.sessionRotated(chapter: 3, reason: "new day, memory not saved", contextTokens: 0)))
        guard case .chapter(_, 3, false, _) = t.items.last else {
            Issue.record("expected unsaved chapter, got \(t.items)")
            return
        }
    }

    @Test mutating func failedOrdinaryTurnDoesNotMarkTheChapter() {
        var t = AgentThread()
        t.apply(ev(.turnCompleted(turnId: "x", status: .error, usage: nil, costUsd: nil)))
        t.apply(ev(.sessionRotated(chapter: 2, reason: "context", contextTokens: 130_000)))
        guard case .chapter(_, 2, true, _) = t.items.last else {
            Issue.record("expected saved chapter item, got \(t.items)")
            return
        }
    }

    @Test mutating func streamedTextSurvivesApproval() {
        var t = AgentThread()
        t.apply(ev(.messageDelta(text: "Pushing"), live: true))
        t.apply(ev(.approvalRequested(approvalId: "ap", callId: "c", tool: "Bash", title: "git push", command: nil, diff: nil, reason: "risky")))
        guard case .assistant(_, "Pushing", _) = t.items[0] else {
            Issue.record("expected finalized stream before the approval")
            return
        }
        #expect(t.pendingApprovals.count == 1)
    }
}
