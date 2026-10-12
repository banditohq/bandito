import Foundation
import Observation
import Testing

@testable import BanditoKit

@Suite struct ActivityFeedTests {
    private let run = ScheduleRun(id: "run-1", name: "Morning summary", firedAt: 1)

    @Test func aQuietRunIsNotAnEntry() {
        let items: [ThreadItem] = [
            .scheduleRun(id: "s1", run: run, prompt: "Check the logs", ts: 1),
            .quietTurn(id: "s2", reason: "nothing_to_report", steps: [], ts: 2),
        ]
        #expect(ActivityFeed.entries(agentID: "a", items: items, readSeq: 0).isEmpty)
    }

    @Test func aScheduledRunThatSpokeCarriesItsScheduleName() {
        let items: [ThreadItem] = [
            .scheduleRun(id: "s1", run: run, prompt: "Summarize", ts: 1),
            .assistant(id: "s2", text: "Three things changed.\nDetails below.", ts: 2),
        ]
        let entries = ActivityFeed.entries(agentID: "a", items: items, readSeq: 1)
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .scheduled(name: "Morning summary"))
        #expect(entries.first?.line == "Three things changed.")
        #expect(entries.first?.seq == 2)
        #expect(entries.first?.isUnread == true)
    }

    @Test func aReplyAfterAPersonMessageIsPlain() {
        let items: [ThreadItem] = [
            .scheduleRun(id: "s1", run: run, prompt: "Summarize", ts: 1),
            .user(id: "s2", text: "Hi", source: .user, from: nil, ts: 2),
            .assistant(id: "s3", text: "Hello", ts: 3),
        ]
        #expect(ActivityFeed.entries(agentID: "a", items: items, readSeq: 0).map(\.kind) == [.reply])
    }

    @Test func errorsAndCreationsAreEntriesButHandOffsAreNot() {
        let items: [ThreadItem] = [
            .note(id: "s3", text: "The build failed.", kind: .error, ts: 3),
            .note(id: "s4", text: "Forge created Scout", kind: .crew, ts: 4),
            .note(id: "s5-n", text: "Message from Forge", kind: .crew, ts: 5),
            .note(id: "s6", text: "Saving memory", kind: .info, ts: 6),
        ]
        let entries = ActivityFeed.entries(agentID: "a", items: items, readSeq: 0)
        #expect(entries.map(\.kind) == [.error, .created])
        #expect(entries.map(\.line) == ["The build failed.", "Forge created Scout"])
        #expect(entries.allSatisfy { !$0.isUnread && $0.seq == nil })
    }

    @Test func repliesAfterTheReadMarkAreUnread() {
        let items: [ThreadItem] = [
            .assistant(id: "s2", text: "First", ts: 2),
            .assistant(id: "s4-s", text: "Second", ts: 4),
        ]
        let entries = ActivityFeed.entries(agentID: "a", items: items, readSeq: 2)
        #expect(entries.map(\.isUnread) == [false, true])
        #expect(entries.last?.seq == 4)
    }

    @Test func aStreamingRowIsNotAnEntry() {
        #expect(ActivityFeed.entries(agentID: "a", items: [.streaming(text: "partial")], readSeq: 0).isEmpty)
    }

    @Test func theFirstNonEmptyLineIsKeptAndCapped() {
        #expect(ActivityFeed.firstLine("\n \n  Hello there  \nsecond") == "Hello there")
        let long = String(repeating: "x", count: 1000)
        #expect(ActivityFeed.firstLine(long).count == ActivityFeed.lineLength)
        #expect(ActivityFeed.firstLine("  \n ").isEmpty)
    }

    @Test func onlyTheNewestEntriesAreKept() {
        let items: [ThreadItem] = (1...(ActivityFeed.perAgentLimit + 100)).map {
            .assistant(id: "s\($0)", text: "Reply \($0)", ts: Int64($0))
        }
        let entries = ActivityFeed.entries(agentID: "a", items: items, readSeq: 0)
        #expect(entries.count == ActivityFeed.perAgentLimit)
        #expect(entries.last?.seq == Int64(ActivityFeed.perAgentLimit + 100))
        #expect(entries.first?.seq == 101)
    }
}

/// Set by an observation's `onChange`, which is `@Sendable`.
private final class ChangeFlag: @unchecked Sendable {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// The summary of an agent's timeline (`AgentThreadState.activity`): it follows the persisted events, not the stream.
@MainActor
@Suite struct ActivitySummaryTests {
    @Test func aStreamedTokenDoesNotTouchTheTimeline() {
        let states = ThreadStates()
        var thread = AgentThread()
        thread.apply(Event(seq: 1, agentId: "a", ts: 1, body: .messageAssistant(text: "Done")))
        states["a"] = thread
        let box = states.box("a")
        #expect(box.activity.count == 1)

        let fired = ChangeFlag()
        withObservationTracking {
            _ = box.activity
        } onChange: {
            fired.set()
        }
        // The stream: seq 0 deltas change the items, never the timeline.
        for piece in 0..<100 {
            thread.apply(Event(seq: 0, agentId: "a", ts: 2, body: .messageDelta(text: "word\(piece) ")))
            states["a"] = thread
        }
        #expect(!fired.isSet, "a streamed reply changed the timeline")
        #expect(box.activity.count == 1)
    }

    @Test func aFinishedReplyJoinsTheTimeline() {
        let states = ThreadStates()
        var thread = AgentThread()
        thread.apply(Event(seq: 1, agentId: "a", ts: 1, body: .messageAssistant(text: "One")))
        states["a"] = thread
        thread.apply(Event(seq: 2, agentId: "a", ts: 2, body: .messageAssistant(text: "Two")))
        states["a"] = thread
        let box = states.box("a")
        #expect(box.activity.map(\.line) == ["One", "Two"])
        // The first sight of the loaded thread read "One"; "Two" arrived after it.
        #expect(box.activity.map(\.isUnread) == [false, true])
        #expect(box.unreadCount == 1)
    }
}
