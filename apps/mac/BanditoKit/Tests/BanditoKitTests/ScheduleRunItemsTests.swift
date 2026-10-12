import Foundation
import Testing

@testable import BanditoKit

/// A scheduled run is one item of its own (`.scheduleRun`), not a note and a bubble; a quiet turn folds its steps into
/// one item (`.quietTurn`). An older daemon's run (no `schedule`) keeps the note and the bubble.
@MainActor
@Suite struct ScheduleRunItemsTests {
    private let agent = "forge"

    private func event(_ seq: Int64, _ body: EventBody) -> Event {
        Event(seq: seq, agentId: agent, ts: 1_700_000_000_000 + seq, body: body)
    }

    private func run(_ seq: Int64, _ text: String = "check the mail") -> Event {
        event(
            seq,
            .messageUser(
                text: text, source: .schedule, fromAgent: nil,
                schedule: ScheduleRun(id: "s1", name: "Mail", firedAt: 1_700_000_000_000 + seq)))
    }

    @Test func aScheduledRunIsOneItemWithItsPrompt() {
        var thread = AgentThread()
        thread.apply(run(1))
        #expect(
            thread.items == [
                .scheduleRun(
                    id: "s1", run: ScheduleRun(id: "s1", name: "Mail", firedAt: 1_700_000_000_001), prompt: "check the mail",
                    ts: 1_700_000_000_001)
            ])
        // Not a message: no preview, no reply to quote.
        #expect(thread.lastMessageText == nil)
        #expect(thread.items.first?.messageSeq == nil)
    }

    @Test func aRunFromAnOlderDaemonKeepsTheNoteAndTheBubble() {
        var thread = AgentThread()
        thread.apply(event(1, .messageUser(text: "check the mail", source: .schedule, fromAgent: nil)))
        #expect(thread.items.count == 2)
        guard case .note(_, _, .schedule, _) = thread.items.first, case .user(_, "check the mail", .schedule, _, _, _) = thread.items.last
        else {
            Issue.record("expected the note and the bubble: \(thread.items)")
            return
        }
    }

    @Test func aQuietTurnFoldsItsStepsUnderTheRun() {
        var thread = AgentThread()
        let events = [
            event(1, .turnStarted(turnId: "t1", source: .schedule)),
            run(2),
            event(3, .toolCall(callId: "c1", tool: "bash", title: "ls mail", input: .null)),
            event(4, .messageDelta(text: "Checking")),
            event(5, .approvalRequested(
                approvalId: "a1", callId: "c9", tool: "bash", title: "rm", command: "rm x", diff: nil, reason: "r")),
            event(6, .turnQuiet(turnId: "t1", reason: "no mail")),
            // A result of a step folded already, and a step after the quiet mark.
            event(7, .toolResult(callId: "c1", ok: true, output: "0")),
            event(8, .toolCall(callId: "c2", tool: "bash", title: "date", input: .null)),
            event(9, .toolResult(callId: "c2", ok: true, output: "now")),
            event(10, .messageAssistant(text: "Nothing new")),
            event(11, .turnCompleted(turnId: "t1", status: .ok, usage: nil, costUsd: nil)),
        ]
        for e in events { thread.apply(e) }

        #expect(thread.items.count == 3)
        guard case .scheduleRun = thread.items[0] else {
            Issue.record("the run's line comes first: \(thread.items)")
            return
        }
        // What waits for the person stays in the thread.
        guard case .approval(let approval) = thread.items[2] else {
            Issue.record("the approval stays: \(thread.items)")
            return
        }
        #expect(approval.approvalId == "a1")
        guard case .quietTurn(_, let reason, let steps, _) = thread.items[1] else {
            Issue.record("the quiet line stands under the run: \(thread.items)")
            return
        }
        #expect(reason == "no mail")
        #expect(steps.map(\.id) == ["tool-c1", "s5-s", "tool-c2"])
        guard case .tool(let first) = steps[0], case .tool(let second) = steps[2], case .assistant(_, let hidden, _) = steps[1]
        else {
            Issue.record("the steps are the tools and the hidden text: \(steps)")
            return
        }
        #expect(first.ok == true && first.output == "0")
        #expect(second.ok == true && second.title == "date")
        #expect(hidden == "Checking")

        // The next turn is an ordinary one: its steps are rows of the thread again.
        thread.apply(event(12, .turnStarted(turnId: "t2", source: .user)))
        thread.apply(event(13, .toolCall(callId: "c3", tool: "bash", title: "pwd", input: .null)))
        #expect(thread.items.last?.id == "tool-c3")
    }

    @Test func aQuietTurnWithNoStepsIsStillOneLine() {
        var thread = AgentThread()
        thread.apply(event(1, .turnStarted(turnId: "t1", source: .schedule)))
        thread.apply(run(2))
        thread.apply(event(3, .turnQuiet(turnId: "t1", reason: nil)))
        thread.apply(event(4, .turnCompleted(turnId: "t1", status: .ok, usage: nil, costUsd: nil)))
        #expect(thread.items.count == 2)
        guard case .quietTurn(_, nil, let steps, _) = thread.items.last else {
            Issue.record("a quiet line: \(thread.items)")
            return
        }
        #expect(steps.isEmpty)
    }
}
