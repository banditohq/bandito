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
        #expect(approval.title.contains("Forge"))
        #expect(approval.title.contains("git push"))
        #expect(approval.categoryID == NotificationContent.approvalCategory)
        #expect(approval.approvalID == "ap1")

        let done = NotificationContent.make(.finished(agentID: "a1", agentName: "Forge"))
        #expect(done.title.contains("Forge"))
        #expect(done.categoryID == nil)

        let failed = NotificationContent.make(.failed(agentID: "a1", agentName: "Forge", message: "boom"))
        #expect(failed.title.contains("Forge"))
        #expect(failed.body.contains("boom"))
    }

    @Test func decisionActionsMapToDecisions() {
        #expect(NotificationContent.decision(forAction: NotificationContent.allowAction) == .allow)
        #expect(NotificationContent.decision(forAction: NotificationContent.denyAction) == .deny)
        #expect(NotificationContent.decision(forAction: "com.apple.UNNotificationDefaultActionIdentifier") == nil)
    }
}
