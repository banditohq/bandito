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
