import Foundation
import Testing

@testable import BanditoKit

/// The rules the phone's Inbox reads from the shared core: which approvals are risky, and what a thread's summary holds
/// of its waiting approvals and quick replies.
@MainActor
@Suite struct InboxSummaryTests {
    @Test func riskyReasonsAreTheRiskyOnes() {
        for reason in ["risky: rm -r", "risky: git push", "reads credentials: ~/.ssh", "writes outside /srv/app", "touches Bandito's files by name"] {
            #expect(ApprovalReason.isRisky(reason), "\(reason) is risky")
        }
        for reason in ["approval required for every action", "rule: git push*", "can't check: eval", "service: confirm tool", "agent: create", ""] {
            #expect(!ApprovalReason.isRisky(reason), "\(reason) is not risky")
        }
    }

    @Test func pendingApprovalRowsFollowTheEvents() {
        let box = AgentThreadState()
        var thread = AgentThread()
        thread.apply(
            Event(
                seq: 1, agentId: "a", ts: 1_000,
                body: .approvalRequested(
                    approvalId: "x", callId: "c", tool: "bash", title: "swift test", command: "swift test", diff: nil,
                    reason: "risky: git push")))
        thread.apply(
            Event(
                seq: 2, agentId: "a", ts: 2_000,
                body: .approvalRequested(
                    approvalId: "y", callId: "d", tool: "bash", title: "ls", command: "ls", diff: nil, reason: "rule: ls")))
        box.thread = thread
        #expect(box.pendingApprovalRows.map(\.approvalId) == ["x", "y"])
        #expect(box.pendingApprovalRows.first?.ts == 1_000)
        #expect(box.pendingApprovalCount == 2)

        thread.apply(
            Event(seq: 3, agentId: "a", ts: 3_000, body: .approvalResolved(approvalId: "x", decision: .allow, by: .user, remember: false)))
        box.thread = thread
        #expect(box.pendingApprovalRows.map(\.approvalId) == ["y"])
    }

    @Test func quickRepliesAreTheNewestSetUntilTheConversationMovesOn() {
        let box = AgentThreadState()
        var thread = AgentThread()
        thread.apply(
            Event(
                seq: 1, agentId: "a", ts: 1_000,
                body: .agentQuickReplies(
                    buttons: [QuickReplyButton(label: "Yes", reply: "Yes."), QuickReplyButton(label: "No", reply: "No.")],
                    link: nil, progress: nil)))
        box.thread = thread
        #expect(box.quickReplies?.buttons.map(\.label) == ["Yes", "No"])

        thread.apply(Event(seq: 2, agentId: "a", ts: 2_000, body: .turnStarted(turnId: "t", source: .user)))
        box.thread = thread
        #expect(box.quickReplies == nil)
    }
}
