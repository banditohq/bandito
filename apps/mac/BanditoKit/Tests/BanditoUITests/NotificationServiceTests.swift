import BanditoKit
import Testing

@testable import BanditoUI

/// Records what would have gone to the system, and which approval buttons were answered.
@MainActor
final class FakeNotificationSink: NotificationService.Sink {
    var posted: [NotificationContent] = []

    func post(_ content: NotificationContent) {
        posted.append(content)
    }
}

@MainActor
@Suite struct NotificationServiceTests {
    final class Answers {
        var calls: [(agentID: String, approvalID: String, decision: Decision)] = []
    }

    func service(sink: FakeNotificationSink, answers: Answers, windowActive: Bool = false, selected: String? = nil) -> NotificationService {
        NotificationService(
            sink: sink,
            settings: { NotificationSettings() },
            windowActive: { windowActive },
            selectedAgentID: { selected },
            resolve: { agentID, approvalID, decision in
                answers.calls.append((agentID, approvalID, decision))
            })
    }

    @Test func handlePostsOnlyWhatTheRulesAllow() {
        let sink = FakeNotificationSink()
        let service = service(sink: sink, answers: Answers(), selected: "a2")
        service.handle(.approval(agentID: "a1", agentName: "Forge", approvalID: "ap1", title: "git push"))
        service.handle(.finished(agentID: "a2", agentName: "Scout"))  // the selected agent: no notice
        service.handle(.finished(agentID: "a1", agentName: "Forge"))
        #expect(sink.posted.count == 2)
        #expect(sink.posted[0].categoryID == NotificationContent.approvalCategory)
        #expect(sink.posted[1].title.contains("Forge"))
    }

    @Test func nothingIsPostedWhileTheWindowIsActive() {
        let sink = FakeNotificationSink()
        let service = service(sink: sink, answers: Answers(), windowActive: true)
        service.handle(.failed(agentID: "a1", agentName: "Forge", message: "boom"))
        #expect(sink.posted.isEmpty)
    }

    @Test func allowAndDenyButtonsAnswerTheApproval() async {
        let answers = Answers()
        let service = service(sink: FakeNotificationSink(), answers: answers)
        await service.handleAction(NotificationContent.allowAction, agentID: "a1", approvalID: "ap1")
        await service.handleAction(NotificationContent.denyAction, agentID: "a1", approvalID: "ap2")
        #expect(answers.calls.count == 2)
        #expect(answers.calls[0].approvalID == "ap1" && answers.calls[0].decision == .allow)
        #expect(answers.calls[1].approvalID == "ap2" && answers.calls[1].decision == .deny)
    }

    @Test func clickOnTheBodyAnswersNothing() async {
        let answers = Answers()
        let service = service(sink: FakeNotificationSink(), answers: answers)
        await service.handleAction("com.apple.UNNotificationDefaultActionIdentifier", agentID: "a1", approvalID: "ap1")
        #expect(answers.calls.isEmpty)
    }
}
