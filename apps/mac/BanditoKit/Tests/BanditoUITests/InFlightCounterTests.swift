import Testing

@testable import BanditoUI

/// The in-flight gate: a screen takes the agent's values only when no send is waiting for an answer.
@Suite struct InFlightCounterTests {
    @Test func startsIdle() {
        #expect(InFlightCounter().isIdle)
    }

    @Test func busyWhileAnySendIsWaiting() {
        var gate = InFlightCounter()
        gate.begin()
        #expect(!gate.isIdle)
        gate.begin()
        gate.end()
        #expect(!gate.isIdle, "one answer is still missing")
        gate.end()
        #expect(gate.isIdle)
    }

    @Test func extraAnswerDoesNotGoNegative() {
        var gate = InFlightCounter()
        gate.end()
        #expect(gate.count == 0)
        gate.begin()
        #expect(!gate.isIdle)
    }
}
