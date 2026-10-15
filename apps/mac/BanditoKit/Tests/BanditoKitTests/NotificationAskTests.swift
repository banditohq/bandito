import Testing

@testable import BanditoKit

/// The question "Want to know when Forge needs you?" comes at the first moment that gives a reason, once.
@Suite struct NotificationAskTests {
    private let approval = AgentNotice.approval(agentID: "a", agentName: "Forge", approvalID: "p", title: "git push")
    private let finished = AgentNotice.finished(agentID: "a", agentName: "Forge", text: nil)

    @Test func anApprovalAndAFinishedTurnAreReasonsToAsk() {
        #expect(NotificationAsk.isReason(approval))
        #expect(NotificationAsk.isReason(finished))
        #expect(NotificationAsk.isReason(.form(agentID: "a", agentName: "Forge", formID: "f")))
        #expect(NotificationAsk.isReason(.question(agentID: "a", agentName: "Forge", text: nil)))
    }

    @Test func aFailureIsNotAReason() {
        #expect(!NotificationAsk.isReason(.failed(agentID: "a", agentName: "Forge", message: "x")))
        #expect(!NotificationAsk.isReason(.resolveFailed(agentID: "a")))
    }

    @Test func theQuestionNamesTheAgent() {
        #expect(NotificationAsk.agentName(approval) == "Forge")
        #expect(NotificationAsk.agentName(finished) == "Forge")
        #expect(NotificationAsk.agentName(.resolveFailed(agentID: "a")) == nil)
    }

    @Test func itIsAskedOnceAndOnlyWhileTheSystemHasNotBeenAsked() {
        #expect(NotificationAsk.shouldAsk(notice: approval, asked: false, systemUndetermined: true))
        #expect(!NotificationAsk.shouldAsk(notice: approval, asked: true, systemUndetermined: true))
        // An earlier version asked at launch: the system knows the answer already.
        #expect(!NotificationAsk.shouldAsk(notice: approval, asked: false, systemUndetermined: false))
        #expect(!NotificationAsk.shouldAsk(notice: .failed(agentID: "a", agentName: "F", message: nil), asked: false, systemUndetermined: true))
    }
}
