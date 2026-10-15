import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// A server's notification scope (`ServerConfig.notifications`) is checked when a notice is shown: `all` lets the global
/// rules decide, `needsYou` keeps only the approvals, `off` keeps none. A notice without a server is not filtered.
@MainActor
@Suite struct ServerNotificationScopeTests {
    private static let server = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    private func service(sink: FakeNotificationSink, scope: NotificationScope) -> NotificationService {
        NotificationService(
            sink: sink,
            settings: { NotificationSettings() },
            windowActive: { false },
            selectedAgentID: { nil },
            resolve: { _, _, _ in },
            scope: { _ in scope })
    }

    private static let approval = AgentNotice.approval(
        agentID: "a1", agentName: "Ana", approvalID: "p1", title: "Run tests")
    private static let finished = AgentNotice.finished(agentID: "a1", agentName: "Ana", text: nil)
    private static let failed = AgentNotice.failed(agentID: "a1", agentName: "Ana", message: "boom")

    @Test func theScopeOffSendsNothingFromThatServer() {
        let sink = FakeNotificationSink()
        let notifications = service(sink: sink, scope: .off)
        notifications.handle(Self.approval, serverID: Self.server)
        notifications.handle(Self.finished, serverID: Self.server)
        notifications.handle(Self.failed, serverID: Self.server)
        #expect(sink.posted.isEmpty)
    }

    @Test func theScopeNeedsYouKeepsOnlyTheApprovals() {
        let sink = FakeNotificationSink()
        let notifications = service(sink: sink, scope: .needsYou)
        notifications.handle(Self.finished, serverID: Self.server)
        notifications.handle(Self.failed, serverID: Self.server)
        #expect(sink.posted.isEmpty)
        notifications.handle(Self.approval, serverID: Self.server)
        #expect(sink.posted.count == 1)
        #expect(sink.posted.first?.approvalID == "p1")
    }

    @Test func theScopeAllLeavesTheDecisionToTheGlobalRules() {
        let sink = FakeNotificationSink()
        let notifications = service(sink: sink, scope: .all)
        notifications.handle(Self.approval, serverID: Self.server)
        notifications.handle(Self.finished, serverID: Self.server)
        #expect(sink.posted.count == 2)
    }

    @Test func aPostedNoticeNamesItsServer() {
        let sink = FakeNotificationSink()
        let notifications = service(sink: sink, scope: .all)
        notifications.handle(Self.approval, serverID: Self.server)
        #expect(sink.posted.first?.serverID == Self.server)
    }

    @Test func aNoticeWithoutAServerIsNotFiltered() {
        let sink = FakeNotificationSink()
        let notifications = service(sink: sink, scope: .off)
        notifications.handle(Self.approval)
        #expect(sink.posted.count == 1)
        #expect(sink.posted.first?.serverID == nil)
    }

    @Test func aFailedAnswerCountsAsWaitingForYou() {
        #expect(AgentNotice.resolveFailed(agentID: "a1").kind == .needsYou)
        #expect(Self.approval.kind == .needsYou)
        #expect(Self.finished.kind == .finished)
        #expect(Self.failed.kind == .failed)
    }
}
