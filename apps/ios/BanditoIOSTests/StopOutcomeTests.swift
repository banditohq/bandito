import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// How a stop of an agent is classified when the daemon refuses it.
@Suite struct StopOutcomeTests {
    /// The daemon says "agent <id> stopped" for an agent that is no longer running: the stop the person asked for.
    @Test func anAgentThatAlreadyStoppedCountsAsSent() {
        let error = RPCError(code: -32000, message: "agent ios-speed-stream stopped")
        #expect(StopOutcome.classify(error) == .sent)
    }

    /// Any other refusal of the daemon is a failure the person can retry.
    @Test func anyOtherRefusalIsAFailure() {
        let error = RPCError(code: -32000, message: "no agent ios-speed-stream")
        #expect(StopOutcome.classify(error) == .failed)
    }

    /// An error that is not the daemon's answer (the call itself broke) is a failure too.
    @Test func aBrokenCallIsAFailure() {
        #expect(StopOutcome.classify(URLError(.timedOut)) == .failed)
    }
}
