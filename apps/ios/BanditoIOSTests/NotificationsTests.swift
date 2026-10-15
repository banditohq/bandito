import BanditoKit
import BanditoL10n
import Foundation
import Testing
import UserNotifications

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// Records what would have gone to the system, and which approval buttons were answered.
@MainActor
final class RecordingSink: NotificationService.Sink {
    var posted: [NotificationContent] = []
    var removed: [String] = []

    func post(_ content: NotificationContent) {
        posted.append(content)
    }

    func removeDelivered(approvalID: String) {
        removed.append(approvalID)
    }
}

/// The answers a fake server received, in order.
@MainActor
final class RecordingAnswers {
    var resolves: [(agentID: String, approvalID: String, decision: Decision)] = []
    var replies: [(agentID: String, text: String)] = []
    var failReplies = false
}

struct Stale: Error {}

/// A service on fakes, and the phone's sink wired to it as the app wires them.
@MainActor
struct PhoneHarness {
    let sink = IOSNotificationSink()
    let system = RecordingSink()
    let answers = RecordingAnswers()
    let service: NotificationService

    init(riskyNeedsFaceID: Bool = true, settings: NotificationSettings = NotificationSettings()) {
        let answers = self.answers
        service = NotificationService(
            sink: system,
            settings: { settings },
            windowActive: { false },
            selectedAgentID: { nil },
            resolve: { agentID, approvalID, decision in
                answers.resolves.append((agentID, approvalID, decision))
            },
            reply: { agentID, text in
                if answers.failReplies { throw Stale() }
                answers.replies.append((agentID, text))
            })
        sink.service = service
        sink.riskyNeedsFaceID = { riskyNeedsFaceID }
    }
}

@MainActor
@Suite struct NotificationsTests {
    // MARK: What a press does

    @Test func theShareReminderOpensItsLinkOnAPress() async throws {
        let harness = PhoneHarness(riskyNeedsFaceID: true)
        var routes: [IOSNotifications.Route] = []
        harness.sink.onRoute = { routes.append($0) }
        let id = UUID()
        await harness.sink.respond(
            action: UNNotificationDefaultActionIdentifier, agentID: "", approvalID: "", risky: false, typed: "",
            link: BanditoLink.share(id: id).url.absoluteString)
        #expect(routes == [.link(BanditoLink.share(id: id).url)])
        #expect(ShareReminder.identifier(for: id) == "share-\(id.uuidString)")
    }

    @Test func riskyAllowWithFaceIDOpensTheSheetAndSendsNothing() async {
        let harness = PhoneHarness(riskyNeedsFaceID: true)
        var routes: [IOSNotifications.Route] = []
        harness.sink.onRoute = { routes.append($0) }
        await harness.sink.respond(
            action: NotificationContent.allowAction, agentID: "a1", approvalID: "ap1", risky: true, typed: "")
        #expect(routes == [.approval(approvalID: "ap1", agentID: "a1")])
        #expect(harness.answers.resolves.isEmpty)
    }

    @Test func riskyAllowWithoutFaceIDResolvesAtOnce() async {
        let harness = PhoneHarness(riskyNeedsFaceID: false)
        var routes: [IOSNotifications.Route] = []
        harness.sink.onRoute = { routes.append($0) }
        await harness.sink.respond(
            action: NotificationContent.allowAction, agentID: "a1", approvalID: "ap1", risky: true, typed: "")
        #expect(routes.isEmpty)
        #expect(harness.answers.resolves.count == 1)
        #expect(harness.answers.resolves.first?.decision == .allow)
        #expect(harness.system.removed == ["ap1"])
    }

    @Test func plainAllowResolvesAtOnce() async {
        let harness = PhoneHarness(riskyNeedsFaceID: true)
        await harness.sink.respond(
            action: NotificationContent.allowAction, agentID: "a1", approvalID: "ap1", risky: false, typed: "")
        #expect(harness.answers.resolves.first?.approvalID == "ap1")
        #expect(harness.answers.resolves.first?.decision == .allow)
    }

    @Test func denyResolvesEvenWhenRisky() async {
        let harness = PhoneHarness(riskyNeedsFaceID: true)
        await harness.sink.respond(
            action: NotificationContent.denyAction, agentID: "a1", approvalID: "ap1", risky: true, typed: "")
        #expect(harness.answers.resolves.first?.decision == .deny)
    }

    @Test func aFailedAnswerTellsTheUser() async {
        let harness = PhoneHarness()
        harness.answers.failReplies = true
        await harness.sink.respond(action: NotificationContent.replyAction, agentID: "a1", approvalID: "", risky: false, typed: "ok")
        #expect(harness.system.posted.count == 1)
        #expect(harness.system.posted.first?.title == L10n.Notify.resolveFailed)
    }

    @Test func aBodyPressOpensTheApprovalOrTheAgent() async {
        let harness = PhoneHarness()
        var routes: [IOSNotifications.Route] = []
        harness.sink.onRoute = { routes.append($0) }
        await harness.sink.respond(
            action: UNNotificationDefaultActionIdentifier, agentID: "a1", approvalID: "ap1", risky: false, typed: "")
        await harness.sink.respond(
            action: UNNotificationDefaultActionIdentifier, agentID: "a1", approvalID: "", risky: false, typed: "")
        #expect(routes == [.approval(approvalID: "ap1", agentID: "a1"), .agent("a1")])
        #expect(harness.answers.resolves.isEmpty)
    }

    @Test func aReplySendsTheTrimmedTextAndEmptyTextSendsNothing() async {
        let harness = PhoneHarness()
        await harness.sink.respond(
            action: NotificationContent.replyAction, agentID: "a1", approvalID: "", risky: false, typed: "  yes\n")
        await harness.sink.respond(
            action: NotificationContent.replyAction, agentID: "a1", approvalID: "", risky: false, typed: "   ")
        #expect(harness.answers.replies.count == 1)
        #expect(harness.answers.replies.first?.text == "yes")
        #expect(harness.answers.replies.first?.agentID == "a1")
    }

    // MARK: Which category, which title, which body

    @Test func aRiskyApprovalUsesTheSheetCategoryOnlyWhenFaceIDIsOn() {
        let risky = NotificationContent.make(
            .approval(agentID: "a1", agentName: "Forge", approvalID: "ap1", title: "git push", command: "git push"))
        var content = risky
        content.risky = true
        #expect(IOSNotificationSink.categoryID(for: content, riskyNeedsFaceID: true) == IOSNotificationSink.riskyCategory)
        #expect(IOSNotificationSink.categoryID(for: content, riskyNeedsFaceID: false) == NotificationContent.approvalCategory)
        #expect(IOSNotificationSink.categoryID(for: risky, riskyNeedsFaceID: true) == NotificationContent.approvalCategory)
    }

    @Test func anApprovalSaysWhoWantsToRunWhatAndAMultiLineOneIsReviewedInTheApp() {
        let plain = NotificationContent.make(
            .approval(agentID: "a1", agentName: "Forge", approvalID: "ap1", title: "git push", command: "git push origin main"))
        #expect(IOSNotificationSink.title(for: plain) == L10n.Notify.wantsToRun(name: "Forge"))
        #expect(IOSNotificationSink.body(for: plain) == "git push origin main")

        let multiline = NotificationContent.make(
            .approval(agentID: "a1", agentName: "Forge", approvalID: "ap2", title: "bash", command: "a\nb\nc"))
        #expect(multiline.categoryID == NotificationContent.approvalReviewCategory)
        #expect(IOSNotificationSink.body(for: multiline) == L10n.Notify.reviewLines(count: 3))
    }

    @Test func otherNoticesKeepTheirTitlesAndQuestionsCarryTheLastMessage() {
        let done = NotificationContent.make(.finished(agentID: "a1", agentName: "Forge", text: nil))
        #expect(IOSNotificationSink.title(for: done) == L10n.Notify.finished(name: "Forge"))
        let question = NotificationContent.make(.question(agentID: "a1", agentName: "Forge", text: "Which branch?"))
        #expect(question.categoryID == IOSNotificationSink.questionCategory)
        #expect(question.title == L10n.Notify.question(name: "Forge"))
        #expect(IOSNotificationSink.body(for: question) == "Which branch?")
        let form = NotificationContent.make(.form(agentID: "a1", agentName: "Forge", formID: "f1"))
        #expect(form.categoryID == NotificationContent.formCategory)
        #expect(form.formID == "f1")
    }

    @Test func theCategoriesOfThePhoneHaveTheirButtons() {
        // The ids the system knows the buttons by: a press is routed by these.
        #expect(NotificationContent.allowAction == "bandito.approval.allow")
        #expect(NotificationContent.denyAction == "bandito.approval.deny")
        #expect(NotificationContent.replyAction == "bandito.question.reply")
        #expect(IOSNotificationSink.riskyCategory == "bandito.approval.risky")
        #expect(NotificationContent.decision(forAction: NotificationContent.replyAction) == nil)
    }

    // MARK: No duplicates, the rules

    @Test func oneEventHasOneIdentifierSoARepeatReplacesIt() {
        let server = UUID()
        let first = NotificationContent.make(.finished(agentID: "a1", agentName: "Forge", text: nil))
        var again = first
        again.key = IOSNotifications.key(serverID: server, seq: 42)
        var repeated = first
        repeated.key = IOSNotifications.key(serverID: server, seq: 42)
        var next = first
        next.key = IOSNotifications.key(serverID: server, seq: 43)
        #expect(IOSNotificationSink.identifier(for: again) == IOSNotificationSink.identifier(for: repeated))
        #expect(IOSNotificationSink.identifier(for: again) != IOSNotificationSink.identifier(for: next))
    }

    @Test func aKeyedNoticeIsPostedOncePerKeyAndTheSettingsDecideTheRest() {
        let harness = PhoneHarness(settings: NotificationSettings(needsYou: false, finished: true, failed: true))
        let server = UUID()
        harness.service.handle(
            .approval(agentID: "a1", agentName: "Forge", approvalID: "ap1", title: "git push"), serverID: server,
            key: IOSNotifications.key(serverID: server, seq: 1))
        harness.service.handle(
            .finished(agentID: "a1", agentName: "Forge", text: nil), serverID: server,
            key: IOSNotifications.key(serverID: server, seq: 2))
        #expect(harness.system.posted.count == 1)
        #expect(harness.system.posted.first?.key == IOSNotifications.key(serverID: server, seq: 2))
    }

    @Test func aRequestAnsweredElsewhereLeavesNoNotification() {
        let harness = PhoneHarness()
        harness.service.approvalSettled("ap9")
        #expect(harness.system.removed == ["ap9"])
    }

    @Test func aFailedTurnIsGroupedByItsAgent() {
        let content = NotificationContent.make(.failed(agentID: "agent-7", agentName: "Forge", message: "boom"))
        #expect(content.agentID == "agent-7")
        #expect(content.body == "boom")
    }

    // MARK: Cursor and routes

    @Test func theCursorOnlyMovesForward() {
        let suite = "dev.bandito.ios.tests.cursor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cursor = NotificationCursor(defaults: defaults)
        let server = UUID()
        #expect(cursor.seq(for: server) == 0)
        cursor.advance(serverID: server, to: 10)
        cursor.advance(serverID: server, to: 7)
        #expect(cursor.seq(for: server) == 10)
        #expect(cursor.seq(for: UUID()) == 0)
    }

    @Test func aRiskyApprovalPressRoutesToTheInboxItem() {
        #expect(IOSNotifications.inboxItemID(approvalID: "ap1") == "approval-ap1")
        #expect(IOSNotifications.routeForPress(agentID: "a1", approvalID: "") == .agent("a1"))
    }

    /// An approval answered on the Mac makes no notice, but the app icon's badge still has to follow it.
    @Test func anEventWithoutANoticeStillRefreshesTheBadge() async {
        let server = await IOSDemo.start()
        let notifications = IOSNotifications()
        notifications.source = StaticNotificationSource(servers: [server])
        var shown: [Int] = []
        notifications.setBadge = { shown.append($0) }
        let resolved = Event(
            seq: 5, agentId: "ios-demo-1", ts: 0,
            body: .approvalResolved(approvalId: "ap-mac", decision: .allow, by: .user, remember: false))
        notifications.ingest(resolved, from: server)
        #expect(shown.count == 1)
    }

    @Test func theBackgroundTaskIsPermittedInTheAppsPlist() {
        let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        #expect(identifiers?.contains(BackgroundRefresh.taskIdentifier) == true)
        #expect(BackgroundRefresh.interval == 15 * 60)
    }
}
