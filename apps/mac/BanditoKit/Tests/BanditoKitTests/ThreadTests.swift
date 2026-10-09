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
        #expect(t.items.count == 2, "streaming text dropped when a tool starts (final text comes as message.assistant)")
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
        guard case .tool(let row) = t.items[1] else { Issue.record("expected tool row"); return }
        #expect(row.ok == true && row.output == "done")
        guard case .approval(let a) = t.items[2] else { Issue.record("expected approval row"); return }
        #expect(a.state == .approved(by: .user, remember: true))
        #expect(t.lastSeq == seq)
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
}
