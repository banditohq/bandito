import Foundation
import Observation
import Testing

@testable import BanditoKit

/// Each agent's thread is observed on its own, and its summary changes only when its values do.
@MainActor
@Suite struct ThreadStatesTests {
    private func event(_ agent: String, _ seq: Int64, _ body: EventBody) -> Event {
        Event(seq: seq, agentId: agent, ts: 1_700_000_000_000 + seq, body: body)
    }

    /// True when `change` fires the observation of what `read` reads.
    private func fires(_ read: @escaping () -> Void, _ change: () -> Void) -> Bool {
        let fired = Box()
        withObservationTracking(read) { fired.value = true }
        change()
        return fired.value
    }

    private final class Box: @unchecked Sendable { var value = false }

    @Test func aTokenInOneThreadDoesNotTouchAnother() {
        let server = ServerModel(config: ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none")))
        server.apply(event("a", 1, .turnStarted(turnId: "t1", source: .user, messageSeq: nil)))
        server.apply(event("b", 2, .turnStarted(turnId: "t2", source: .user, messageSeq: nil)))
        #expect(!fires({ _ = server.thread(for: "b") }) {
            server.apply(event("a", 0, .messageDelta(text: "hello")))
        })
        #expect(fires({ _ = server.thread(for: "a") }) {
            server.apply(event("a", 0, .messageDelta(text: " world")))
        })
    }

    @Test func aTokenDoesNotTouchTheSummary() {
        let server = ServerModel(config: ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none")))
        server.apply(event("a", 1, .turnStarted(turnId: "t1", source: .user, messageSeq: nil)))
        let summary = server.threadSummary(for: "a")
        #expect(summary.turnRunning)
        #expect(!fires({ _ = summary.turnRunning; _ = summary.loadedStatus; _ = summary.pendingApprovalCount }) {
            server.apply(event("a", 0, .messageDelta(text: "token")))
        })
        #expect(fires({ _ = summary.turnRunning }) {
            server.apply(event("a", 2, .turnCompleted(turnId: "t1", status: .ok, usage: nil, costUsd: nil)))
        })
        #expect(!summary.turnRunning)
    }

    @Test func aStreamedPreviewIsWrittenAtMostOncePerInterval() async throws {
        let box = AgentThreadState()
        box.previewInterval = .milliseconds(80)
        var thread = AgentThread()
        thread.items = [.assistant(id: "m1", text: "Earlier reply", ts: 1)]
        box.thread = thread
        #expect(box.lastMessageHead == "Earlier reply")
        // The stream starts: its first words show at once only after the interval since the last write.
        box.thread.items.append(.streaming(text: "Hel"))
        #expect(box.lastMessageHead == "Earlier reply")
        #expect(!fires({ _ = box.lastMessageHead }) { box.thread.items[1] = .streaming(text: "Hello wor") })
        // After the interval the latest text is written (waited for: the main actor may be busy with other tests).
        for _ in 0..<1500 where box.lastMessageHead != "Hello wor" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(box.lastMessageHead == "Hello wor")
        // The settled reply is written at once.
        box.thread.items[1] = .assistant(id: "m2", text: "Hello world", ts: 2)
        #expect(box.lastMessageHead == "Hello world")
    }

    @Test func theThrottleWaitsOutTheInterval() {
        let start = ContinuousClock.now
        #expect(StreamPreviewThrottle.wait(since: start, now: start + .milliseconds(100), interval: .milliseconds(300))
            == .milliseconds(200))
        #expect(StreamPreviewThrottle.wait(since: start, now: start + .milliseconds(300), interval: .milliseconds(300)) == nil)
    }

    @Test func aThreadReadBeforeItWasLoadedIsNil() {
        let states = ThreadStates()
        #expect(states["x"] == nil)
        states["x"] = AgentThread()
        #expect(states["x"] != nil)
        states["x"] = nil
        #expect(states["x"] == nil)
        #expect(!states.box("x").loaded)
    }
}
