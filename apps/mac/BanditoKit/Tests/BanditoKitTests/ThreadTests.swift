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
