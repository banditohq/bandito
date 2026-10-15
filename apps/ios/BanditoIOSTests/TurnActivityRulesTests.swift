import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// When a long turn gets a Live Activity, what moves it, and when the system removes it.
@Suite struct TurnActivityRulesTests {
    private typealias Rules = TurnActivityRules
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func start(
        elapsed: TimeInterval = 31, active: Bool = true, enabled: Bool = true, existing: TurnActivityRules.Phase? = nil,
        running: Int = 0, dismissed: Bool = false
    ) -> TurnActivityRules.StartAction {
        Rules.startAction(
            elapsed: elapsed, appActive: active, enabled: enabled, existing: existing, running: running,
            dismissedThisTurn: dismissed)
    }

    @Test func startsOnlyAfterThirtySeconds() {
        #expect(start(elapsed: 29.9) == .none)
        #expect(start(elapsed: 30) == .start)
        #expect(start(elapsed: 600) == .start)
    }

    @Test func needsTheAppActiveAndTheSettingOn() {
        #expect(start(active: false) == .none)
        #expect(start(enabled: false) == .none)
    }

    @Test func oneActivityPerAgent() {
        #expect(start(existing: .running) == .none)
        #expect(start(existing: .needsYou) == .none)
        // A second turn after an ended one replaces its activity instead of adding another.
        #expect(start(existing: .done) == .restart)
        #expect(start(existing: .failed) == .restart)
    }

    @Test func atMostThreeAtOnce() {
        #expect(start(running: 2) == .start)
        #expect(start(running: 3) == .none)
        // A restart takes the agent's own place, so it is not blocked by the others.
        #expect(start(existing: .done, running: 3) == .restart)
    }

    @Test func aSwipedAwayActivityDoesNotComeBackInTheSameTurn() {
        #expect(start(dismissed: true) == .none)
        #expect(start(existing: .done, dismissed: true) == .none)
    }

    @Test func dueTimeCountsFromTheStart() {
        #expect(Rules.delayUntilDue(startedAt: now, now: now) == 30)
        #expect(Rules.delayUntilDue(startedAt: now.addingTimeInterval(-12), now: now) == 18)
        #expect(Rules.delayUntilDue(startedAt: now.addingTimeInterval(-90), now: now) == 0)
    }

    @Test func aStartInTheFutureCountsAsNow() {
        #expect(Rules.clampedStart(now.addingTimeInterval(40), now: now) == now)
        #expect(Rules.clampedStart(now.addingTimeInterval(-40), now: now) == now.addingTimeInterval(-40))
    }

    @Test func doingChangesAtMostEveryFiveSeconds() {
        #expect(Rules.shouldUpdateDoing(current: "A", new: "B", lastUpdate: nil, now: now))
        #expect(!Rules.shouldUpdateDoing(current: "A", new: "B", lastUpdate: now.addingTimeInterval(-4.9), now: now))
        #expect(Rules.shouldUpdateDoing(current: "A", new: "B", lastUpdate: now.addingTimeInterval(-5), now: now))
    }

    @Test func doingIsNotRewrittenWithTheSameText() {
        #expect(!Rules.shouldUpdateDoing(current: "A", new: "A", lastUpdate: nil, now: now))
        #expect(!Rules.shouldUpdateDoing(current: "A", new: "A", lastUpdate: now.addingTimeInterval(-60), now: now))
    }

    @Test func aThrottledLineWaitsTheRestOfTheInterval() {
        #expect(Rules.doingWait(lastUpdate: nil, now: now) == 0)
        #expect(Rules.doingWait(lastUpdate: now.addingTimeInterval(-2), now: now) == 3)
        #expect(Rules.doingWait(lastUpdate: now.addingTimeInterval(-9), now: now) == 0)
    }

    @Test func theLineIsOneShortLine() {
        #expect(Rules.clean("  Running\ntests \n") == "Running tests")
        #expect(Rules.clean(String(repeating: "x", count: 500)).count == Rules.doingLimit)
        #expect(Rules.clean("") == "")
    }

    @Test func aFinishedTurnIsDoneAndABrokenOneIsFailed() {
        func completed(_ status: TurnStatus) -> EventBody {
            .turnCompleted(turnId: "t", status: status, usage: nil, costUsd: nil)
        }
        #expect(Rules.phase(after: completed(.ok), stillWaiting: false) == .done)
        #expect(Rules.phase(after: completed(.error), stillWaiting: false) == .failed)
        #expect(Rules.phase(after: completed(.interrupted), stillWaiting: false) == .failed)
        // A turn that ends while the person still owes an answer ends on "needs you".
        #expect(Rules.phase(after: completed(.ok), stillWaiting: true) == .needsYou)
        #expect(Rules.phase(after: completed(.error), stillWaiting: true) == .failed)
    }

    @Test func anApprovalAFormAndAQuestionNeedThePerson() {
        let approval = EventBody.approvalRequested(
            approvalId: "a", callId: "c", tool: "bash", title: "git push", command: nil, diff: nil, reason: "")
        #expect(Rules.phase(after: approval, stillWaiting: true) == .needsYou)
        #expect(Rules.phase(after: .agentStatus(status: .needsYou, detail: nil), stillWaiting: false) == .needsYou)
    }

    @Test func answeringBringsTheTurnBackToRunning() {
        let resolved = EventBody.approvalResolved(approvalId: "a", decision: .allow, by: .user, remember: false)
        #expect(Rules.phase(after: resolved, stillWaiting: false) == .running)
        #expect(Rules.phase(after: resolved, stillWaiting: true) == .needsYou)
        #expect(Rules.phase(after: .agentStatus(status: .working, detail: nil), stillWaiting: false) == .running)
    }

    @Test func otherEventsChangeNothing() {
        #expect(Rules.phase(after: .messageAssistant(text: "hi"), stillWaiting: false) == nil)
        #expect(Rules.phase(after: .agentStatus(status: .idle, detail: nil), stillWaiting: false) == nil)
    }

    @Test func theSystemRemovesAnEndedActivityAfterFifteenMinutesOrAnHour() {
        #expect(Rules.dismissal(for: .done) == 15 * 60)
        #expect(Rules.dismissal(for: .failed) == 15 * 60)
        #expect(Rules.dismissal(for: .needsYou) == 60 * 60)
        #expect(Rules.dismissal(for: .running) == nil)
        #expect(Rules.isFinal(.done) && Rules.isFinal(.failed))
        #expect(!Rules.isFinal(.running) && !Rules.isFinal(.needsYou))
    }

    @Test func anActivityLeftByAKilledAppIsFound() {
        // The server is gone.
        #expect(Rules.isOrphan(phase: .running, serverKnown: false, serverConnected: false, turnRunning: false))
        // The server answers and the agent has no turn.
        #expect(Rules.isOrphan(phase: .running, serverKnown: true, serverConnected: true, turnRunning: false))
        #expect(Rules.isOrphan(phase: .needsYou, serverKnown: true, serverConnected: true, turnRunning: false))
        // The turn runs; or the server is not connected, so nothing is known yet; or the activity already ended.
        #expect(!Rules.isOrphan(phase: .running, serverKnown: true, serverConnected: true, turnRunning: true))
        #expect(!Rules.isOrphan(phase: .running, serverKnown: true, serverConnected: false, turnRunning: false))
        #expect(!Rules.isOrphan(phase: .done, serverKnown: false, serverConnected: false, turnRunning: false))
    }
}
