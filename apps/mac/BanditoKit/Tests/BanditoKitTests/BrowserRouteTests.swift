import Foundation
import Testing

@testable import BanditoKit

// The browser routes' parameters, the errors their HTTP answers map to, and the reconnect policy
// (docs/ARCHITECTURE.md#browser). The addresses and tokens of the routes are in DaemonRouteTests.

@Test func targetIDsAreOneToSixtyFourLettersOrDigits() {
    #expect(BrowserRoute.isValidTargetID("ABC123"))
    #expect(BrowserRoute.isValidTargetID(String(repeating: "A", count: 64)))
    for bad in ["", "a/b", "a-b", "a b", String(repeating: "A", count: 65), "é1", "A?x"] {
        #expect(!BrowserRoute.isValidTargetID(bad), "\(bad)")
    }
}

@Test func routeAnswersMapToTheirErrors() {
    #expect(CDPError.routeError(status: 409) == .browserNotRunning)
    #expect(CDPError.routeError(status: 404) == .noSuchTab)
    #expect(CDPError.routeError(status: 429) == .tooManySockets)
    #expect(CDPError.routeError(status: 401) == .unauthorized)
    #expect(CDPError.routeError(status: 403) == .unauthorized)
    #expect(CDPError.routeError(status: 500) == .httpStatus(500))
}

@Test func reconnectWaitsTwoSecondsBetweenAttempts() {
    var policy = BrowserReconnectPolicy()
    #expect(policy.next(at: 0) == .attempt(1))
    #expect(policy.next(at: 1) == .wait(until: 2))
    #expect(policy.next(at: 2) == .attempt(2))
    #expect(policy.next(at: 2.5) == .wait(until: 4))
}

@Test func fiveFailuresInARowGiveUpUntilAConnectionWorks() {
    var policy = BrowserReconnectPolicy()
    var now: TimeInterval = 0
    for attempt in 1...BrowserReconnectPolicy.maxAttempts {
        #expect(policy.next(at: now) == .attempt(attempt))
        now += 2
    }
    #expect(policy.next(at: now) == .giveUp)
    #expect(policy.next(at: now + 3600) == .giveUp)
    policy.succeeded()
    #expect(policy.next(at: now) == .attempt(1))
}

@Test func aConnectionThatShowsSomethingRestartsTheCount() {
    var policy = BrowserReconnectPolicy()
    #expect(policy.next(at: 0) == .attempt(1))
    #expect(policy.next(at: 1) == .wait(until: 2))
    policy.succeeded()
    #expect(policy.attempts == 0)
    // After a success the next drop is retried at once, not after the old wait.
    #expect(policy.next(at: 1) == .attempt(1))
}

@Test func workspaceIsAQueryOnlyWhenNamed() {
    #expect(BrowserRoute.query(workspace: nil).isEmpty)
    let named = BrowserRoute.query(workspace: "work")
    #expect(named.count == 1)
    #expect(named.first?.name == "workspace")
    #expect(named.first?.value == "work")
}

