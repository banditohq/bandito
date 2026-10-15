import Foundation
import Testing

@testable import BanditoKit

@Suite struct TurnTextTests {
    /// The reply of the running turn is the last text its agent wrote; a turn that wrote none has none.
    @Test func theLastTextOfTheTurnIsItsReply() {
        var t = AgentThread()
        t.apply(Event(seq: 1, agentId: "a", ts: 1, body: .turnStarted(turnId: "t1", source: .user)))
        t.apply(Event(seq: 2, agentId: "a", ts: 2, body: .messageAssistant(text: "первое")))
        t.apply(Event(seq: 3, agentId: "a", ts: 3, body: .messageAssistant(text: "второе")))
        #expect(t.lastTurnText == "второе")
        t.apply(Event(
            seq: 4, agentId: "a", ts: 4, body: .turnCompleted(turnId: "t1", status: .ok, usage: nil, costUsd: nil)))
        #expect(t.lastTurnText == "второе")
        t.apply(Event(seq: 5, agentId: "a", ts: 5, body: .turnStarted(turnId: "t2", source: .user)))
        #expect(t.lastTurnText == nil)
    }
}
