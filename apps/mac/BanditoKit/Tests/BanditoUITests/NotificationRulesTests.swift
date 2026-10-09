import Testing

@testable import BanditoUI

@Suite struct NotificationRulesTests {
    let all = NotificationSettings(needsYou: true, finished: true, failed: true)

    @Test func approvalNotifiesOnlyWhenWindowIsInactive() {
        let notice = AgentNotice.approval(agentID: "a1", agentName: "Forge", approvalID: "ap1", title: "git push")
        #expect(NotificationRules.shouldDeliver(notice, settings: all, windowActive: false, selectedAgentID: nil))
        #expect(!NotificationRules.shouldDeliver(notice, settings: all, windowActive: true, selectedAgentID: nil))
    }

    @Test func approvalRespectsItsSetting() {
        let notice = AgentNotice.approval(agentID: "a1", agentName: "Forge", approvalID: "ap1", title: "git push")
        let off = NotificationSettings(needsYou: false, finished: true, failed: true)
        #expect(!NotificationRules.shouldDeliver(notice, settings: off, windowActive: false, selectedAgentID: nil))
    }

    @Test func finishedSkipsTheSelectedAgent() {
        let notice = AgentNotice.finished(agentID: "a1", agentName: "Forge")
        #expect(!NotificationRules.shouldDeliver(notice, settings: all, windowActive: false, selectedAgentID: "a1"))
        #expect(NotificationRules.shouldDeliver(notice, settings: all, windowActive: false, selectedAgentID: "a2"))
        #expect(!NotificationRules.shouldDeliver(notice, settings: all, windowActive: true, selectedAgentID: "a2"))
    }

    @Test func failureNotifiesWhenWindowIsInactive() {
        let notice = AgentNotice.failed(agentID: "a1", agentName: "Forge", message: "boom")
        #expect(NotificationRules.shouldDeliver(notice, settings: all, windowActive: false, selectedAgentID: nil))
        let off = NotificationSettings(needsYou: true, finished: true, failed: false)
        #expect(!NotificationRules.shouldDeliver(notice, settings: off, windowActive: false, selectedAgentID: nil))
    }

    @Test func contentNamesTheAgentAndTheTitle() {
        let approval = NotificationContent.make(
            .approval(agentID: "a1", agentName: "Forge", approvalID: "ap1", title: "git push"))
        // The title names the agent only; the command's short title is the body.
        #expect(approval.title.contains("Forge"))
        #expect(!approval.title.contains("git push"))
        #expect(approval.body == "git push")
        #expect(approval.categoryID == NotificationContent.approvalCategory)
        #expect(approval.approvalID == "ap1")

        let done = NotificationContent.make(.finished(agentID: "a1", agentName: "Forge"))
        #expect(done.title.contains("Forge"))
        #expect(done.categoryID == NotificationContent.finishedCategory)

        let failed = NotificationContent.make(.failed(agentID: "a1", agentName: "Forge", message: "boom"))
        #expect(failed.title.contains("Forge"))
        #expect(failed.body.contains("boom"))
    }

    @Test func everyNoticeHasACategoryExceptTheFailedAnswer() {
        #expect(NotificationContent.make(.failed(agentID: "a", agentName: "F", message: nil)).categoryID
            == NotificationContent.failedCategory)
        #expect(NotificationContent.make(.resolveFailed(agentID: "a")).categoryID == nil)
    }

    @Test func singleShortCommandGetsAllowAndDeny() {
        #expect(NotificationContent.approvalCategoryID(command: "git status") == NotificationContent.approvalCategory)
        #expect(NotificationContent.approvalCategoryID(command: nil) == NotificationContent.approvalCategory)
    }

    @Test func multilineCommandGetsTheReviewCategoryAndACount() {
        let command = "cd /app\nrm -rf build\ngit push"
        #expect(NotificationContent.approvalCategoryID(command: command) == NotificationContent.approvalReviewCategory)
        let content = NotificationContent.make(
            .approval(agentID: "a1", agentName: "Forge", approvalID: "ap1", title: "git push", command: command))
        #expect(content.categoryID == NotificationContent.approvalReviewCategory)
        #expect(content.body.contains("3"))
        #expect(!content.body.contains("git push"))
    }

    @Test func longCommandGetsTheReviewCategory() {
        let long = String(repeating: "a", count: NotificationContent.longCommandLimit + 1)
        #expect(NotificationContent.approvalCategoryID(command: long) == NotificationContent.approvalReviewCategory)
        let exact = String(repeating: "a", count: NotificationContent.longCommandLimit)
        #expect(NotificationContent.approvalCategoryID(command: exact) == NotificationContent.approvalCategory)
    }

    @Test func decisionActionsMapToDecisions() {
        #expect(NotificationContent.decision(forAction: NotificationContent.allowAction) == .allow)
        #expect(NotificationContent.decision(forAction: NotificationContent.denyAction) == .deny)
        #expect(NotificationContent.decision(forAction: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
    }
}
