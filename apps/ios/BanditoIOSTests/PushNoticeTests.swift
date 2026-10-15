import BanditoKit
import BanditoL10n
import CryptoKit
import Foundation
import Testing
import UserNotifications

@testable import Bandito

/// Opening a push and making its notification (docs/IOS_APP.md, Push payload).
@Suite struct PushNoticeTests {
    static let handle = "h-4f2a"

    /// A push as the daemon sends it: the open text sealed with the server's key and the phone's handle.
    static func push(_ json: String, key: SymmetricKey, handle: String = PushNoticeTests.handle) throws -> [AnyHashable: Any] {
        let sealed = try PushCrypto.seal(Data(json.utf8), handle: handle, key: key)
        return ["aps": ["alert": ["title": "Bandito", "body": "Forge needs you"]], "ct": sealed.ct, "nonce": sealed.nonce,
            "kind": "approval"]
    }

    static func text(
        seq: Int = 41, agent: String = "agent-1", name: String? = "Forge", event: String, server: String = "S1"
    ) -> String {
        let nameField = name.map { #""name":"\#($0)","# } ?? ""
        return #"{"v":1,"srv":"\#(server)","seq":\#(seq),"agent":"\#(agent)",\#(nameField)"ts":1700000000000,"event":\#(event)}"#
    }

    static let approval =
        #"{"kind":"approval.requested","payload":{"approval_id":"ap1","call_id":"c1","tool":"bash","title":"Run git status","command":"git status","diff":null,"reason":"rule: ask"}}"#

    static func plan(_ json: String, riskyNeedsFaceID: Bool = true) -> PushNoticeBuilder.Plan? {
        PushNoticeBuilder.plan(plain: Data(json.utf8), serverRef: "S1", riskyNeedsFaceID: riskyNeedsFaceID)
    }

    // MARK: opening

    @Test func aPushSealedWithTheKeyAndTheHandleOpens() throws {
        let key = SymmetricKey(size: .bits256)
        let info = try Self.push(Self.text(event: Self.approval), key: key)
        let opened = PushCrypto.open(userInfo: info, handle: Self.handle, keys: [("S1", key)])
        #expect(opened?.serverRef == "S1")
        #expect(opened.flatMap { String(data: $0.plain, encoding: .utf8) } == Self.text(event: Self.approval))
    }

    @Test func anotherKeyOrAnotherHandleOpensNothing() throws {
        let key = SymmetricKey(size: .bits256)
        let info = try Self.push(Self.text(event: Self.approval), key: key)
        #expect(PushCrypto.open(userInfo: info, handle: Self.handle, keys: [("S2", SymmetricKey(size: .bits256))]) == nil)
        #expect(PushCrypto.open(userInfo: info, handle: "other", keys: [("S1", key)]) == nil)
        #expect(PushCrypto.open(userInfo: info, handle: Self.handle, keys: []) == nil)
    }

    @Test func theRightKeyIsFoundAmongSeveral() throws {
        let keys = (1...3).map { ("S\($0)", SymmetricKey(size: .bits256)) }
        let info = try Self.push(Self.text(event: Self.approval, server: "S3"), key: keys[2].1)
        #expect(PushCrypto.open(userInfo: info, handle: Self.handle, keys: keys)?.serverRef == "S3")
    }

    @Test func aDamagedPushOpensNothing() throws {
        let key = SymmetricKey(size: .bits256)
        var info = try Self.push(Self.text(event: Self.approval), key: key)
        let ct = info["ct"] as! String
        var raw = Data(base64Encoded: ct)!
        raw[0] ^= 1
        info["ct"] = raw.base64EncodedString()
        #expect(PushCrypto.open(userInfo: info, handle: Self.handle, keys: [("S1", key)]) == nil)
        info["ct"] = "!!not base64"
        #expect(PushCrypto.open(userInfo: info, handle: Self.handle, keys: [("S1", key)]) == nil)
        info["ct"] = Data(repeating: 1, count: 5).base64EncodedString()
        #expect(PushCrypto.open(userInfo: info, handle: Self.handle, keys: [("S1", key)]) == nil)
        info["ct"] = ct
        info["nonce"] = Data(repeating: 0, count: 8).base64EncodedString()
        #expect(PushCrypto.open(userInfo: info, handle: Self.handle, keys: [("S1", key)]) == nil)
        #expect(PushCrypto.open(userInfo: ["aps": [:]], handle: Self.handle, keys: [("S1", key)]) == nil)
    }

    /// The vector of the daemon's test (RFC 8439 shape): ciphertext, then the 16-byte tag, then the associated data.
    @Test func theTagFollowsTheCiphertext() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let sealed = try PushCrypto.seal(
            Data("hi".utf8), handle: "h", key: key, nonce: Data(repeating: 9, count: 12))
        let raw = Data(base64Encoded: sealed.ct)!
        #expect(raw.count == 2 + 16)
        #expect(sealed.nonce == Data(repeating: 9, count: 12).base64EncodedString())
    }

    // MARK: the notification

    @Test func anApprovalOffersAllowAndDenyAndCarriesWhatAPressNeeds() throws {
        let plan = try #require(Self.plan(Self.text(event: Self.approval)))
        #expect(plan.fields.title == L10n.Notify.wantsToRun(name: "Forge"))
        #expect(plan.fields.body == "git status")
        #expect(plan.fields.categoryID == NotificationContent.approvalCategory)
        #expect(plan.fields.threadID == "agent-1")
        #expect(plan.fields.userInfo["agentID"] as? String == "agent-1")
        #expect(plan.fields.userInfo["approvalID"] as? String == "ap1")
        #expect(plan.fields.userInfo["formID"] as? String == "")
        #expect(plan.fields.userInfo["risky"] as? Bool == false)
        #expect(plan.fields.userInfo["server"] as? String == "S1")
        #expect(plan.seq == 41)
        #expect(plan.noticeKey == "S1:41")
    }

    @Test func aRiskyApprovalAsksForTheAppWhenFaceIDIsOn() throws {
        let risky = Self.approval.replacingOccurrences(of: "rule: ask", with: "risky: git push")
        let on = try #require(Self.plan(Self.text(event: risky), riskyNeedsFaceID: true))
        #expect(on.fields.categoryID == PhoneNotice.riskyCategory)
        #expect(on.fields.userInfo["risky"] as? Bool == true)
        let off = try #require(Self.plan(Self.text(event: risky), riskyNeedsFaceID: false))
        #expect(off.fields.categoryID == NotificationContent.approvalCategory)
    }

    @Test func aLongOrMultiLineCommandIsReviewedInTheApp() throws {
        let multi = Self.approval.replacingOccurrences(of: "git status", with: "a\\nb\\nc")
        let plan = try #require(Self.plan(Self.text(event: multi)))
        #expect(plan.fields.categoryID == NotificationContent.approvalReviewCategory)
        #expect(plan.fields.body == L10n.Notify.reviewLines(count: 3))
    }

    @Test func aFormIsAQuestionWithoutButtons() throws {
        let form = #"{"kind":"form_requested","payload":{"form_id":"f1","title":"Deploy?","kind":"question","fields":[]}}"#
        let plan = try #require(Self.plan(Self.text(event: form)))
        #expect(plan.fields.title == L10n.Notify.form(name: "Forge"))
        #expect(plan.fields.categoryID == NotificationContent.formCategory)
        #expect(plan.fields.userInfo["formID"] as? String == "f1")
        #expect(plan.fields.userInfo["approvalID"] as? String == "")
    }

    @Test func anAgentThatNeedsYouAsksAQuestionWithAReply() throws {
        let status = #"{"kind":"agent.status","payload":{"status":"needs_you"}}"#
        let plan = try #require(Self.plan(Self.text(event: status)))
        #expect(plan.fields.title == L10n.Notify.question(name: "Forge"))
        #expect(plan.fields.categoryID == NotificationContent.questionCategory)
    }

    @Test func aFinishedTurnAndAnErrorHaveTheirOwnTitles() throws {
        let done = #"{"kind":"turn.completed","payload":{"turn_id":"t","status":"ok"}}"#
        let finished = try #require(Self.plan(Self.text(event: done)))
        #expect(finished.fields.title == L10n.Notify.finished(name: "Forge"))
        #expect(finished.fields.categoryID == NotificationContent.finishedCategory)
        let error = #"{"kind":"error","payload":{"message":"boom"}}"#
        let failed = try #require(Self.plan(Self.text(event: error)))
        #expect(failed.fields.title == L10n.Notify.failed(name: "Forge"))
        #expect(failed.fields.body == "boom")
        #expect(failed.fields.categoryID == NotificationContent.failedCategory)
    }

    /// The daemon cuts what does not fit: only `{kind}` is left (and an approval's id when it fits).
    @Test func aCutDownEventStillMakesATextForItsKind() throws {
        let done = try #require(Self.plan(Self.text(event: #"{"kind":"turn.completed"}"#)))
        #expect(done.fields.title == L10n.Notify.finished(name: "Forge"))
        let error = try #require(Self.plan(Self.text(event: #"{"kind":"error"}"#)))
        #expect(error.fields.title == L10n.Notify.failed(name: "Forge"))
        #expect(error.fields.body == "")
        let question = try #require(Self.plan(Self.text(event: #"{"kind":"agent.status"}"#)))
        #expect(question.fields.categoryID == NotificationContent.questionCategory)
        let form = try #require(Self.plan(Self.text(event: #"{"kind":"form_requested","payload":{"form_id":"f9"}}"#)))
        #expect(form.fields.userInfo["formID"] as? String == "f9")
    }

    @Test func aCutDownApprovalOffersDenyAndOpeningTheApp() throws {
        let kept = try #require(
            Self.plan(Self.text(event: #"{"kind":"approval.requested","payload":{"approval_id":"ap7"}}"#)))
        #expect(kept.fields.categoryID == NotificationContent.approvalReviewCategory)
        #expect(kept.fields.userInfo["approvalID"] as? String == "ap7")
        #expect(kept.fields.body == L10n.Notify.reviewLong)
        // With no id at all there is nothing a button could answer.
        let bare = try #require(Self.plan(Self.text(event: #"{"kind":"approval.requested"}"#)))
        #expect(bare.fields.categoryID == NotificationContent.finishedCategory)
        #expect(bare.fields.userInfo["approvalID"] as? String == "")
    }

    @Test func aTextThisVersionDoesNotReadMakesNoPlan() {
        #expect(Self.plan(#"{"v":2,"agent":"a","name":"F","seq":1,"event":{"kind":"error"}}"#) == nil)
        #expect(Self.plan("not json") == nil)
        // No name left (the daemon's last cut): the cloud's own text stays.
        #expect(Self.plan(Self.text(name: nil, event: #"{"kind":"error"}"#)) == nil)
        // A kind that makes no notice.
        #expect(Self.plan(Self.text(event: #"{"kind":"relay.changed"}"#)) == nil)
    }

    // MARK: the extension's whole job

    private func keychain(_ key: SymmetricKey, ref: String = "S1", handle: String? = PushNoticeTests.handle) throws -> PushKeychain {
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        try keychain.save(key, for: ref)
        if let handle {
            try keychain.save(PushRegistration(token: "aa", env: "sandbox", handle: handle))
        }
        return keychain
    }

    private func original(_ info: [AnyHashable: Any]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Bandito"
        content.body = "Forge needs you"
        content.userInfo = info
        content.categoryIdentifier = "BANDITO_APPROVAL"
        return content
    }

    private func shared() -> (PushShared, () -> Void) {
        let suite = "dev.bandito.ios.tests.pushshared.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PushShared(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func theExtensionShowsTheOpenedNoticeAndNotesTheEvent() throws {
        let key = SymmetricKey(size: .bits256)
        let (shared, cleanup) = shared()
        defer { cleanup() }
        let info = try Self.push(Self.text(event: Self.approval), key: key)
        let outcome = PushContent.make(for: original(info), keychain: try keychain(key), shared: shared)
        #expect(outcome.content.title == L10n.Notify.wantsToRun(name: "Forge"))
        #expect(outcome.content.body == "git status")
        #expect(outcome.content.categoryIdentifier == NotificationContent.approvalCategory)
        #expect(outcome.content.threadIdentifier == "agent-1")
        #expect(outcome.content.userInfo["server"] as? String == "S1")
        #expect(outcome.replacesKey == "S1:41")
        #expect(shared.lastSeq(for: "S1") == 41)
    }

    @Test func aRiskyApprovalFollowsTheSharedFaceIDChoice() throws {
        let key = SymmetricKey(size: .bits256)
        let (shared, cleanup) = shared()
        defer { cleanup() }
        let risky = Self.approval.replacingOccurrences(of: "rule: ask", with: "risky: sudo")
        let info = try Self.push(Self.text(event: risky), key: key)
        let on = PushContent.make(for: original(info), keychain: try keychain(key), shared: shared)
        #expect(on.content.categoryIdentifier == PhoneNotice.riskyCategory)
        shared.riskyNeedsFaceID = false
        let off = PushContent.make(for: original(info), keychain: try keychain(key), shared: shared)
        #expect(off.content.categoryIdentifier == NotificationContent.approvalCategory)
    }

    @Test func aPushThatDoesNotOpenKeepsTheCloudsTextWithoutButtons() throws {
        let (shared, cleanup) = shared()
        defer { cleanup() }
        let info = try Self.push(Self.text(event: Self.approval), key: SymmetricKey(size: .bits256))
        let outcome = PushContent.make(
            for: original(info), keychain: try keychain(SymmetricKey(size: .bits256)), shared: shared)
        #expect(outcome.content.title == "Bandito")
        #expect(outcome.content.body == "Forge needs you")
        #expect(outcome.content.categoryIdentifier == NotificationContent.finishedCategory)
        #expect(outcome.replacesKey == nil)
        #expect(shared.lastSeq(for: "S1") == 0)
        // No handle at all (the phone never registered): the same.
        let none = PushContent.make(for: original(info), keychain: PushKeychain(secrets: MemoryPushSecrets()), shared: shared)
        #expect(none.content.categoryIdentifier == NotificationContent.finishedCategory)
    }

    @Test func theNotedEventOnlyMovesForward() {
        let (shared, cleanup) = shared()
        defer { cleanup() }
        shared.noteSeq(10, for: "S1")
        shared.noteSeq(7, for: "S1")
        #expect(shared.lastSeq(for: "S1") == 10)
        #expect(shared.lastSeq(for: "S2") == 0)
        shared.forgetSeq(for: "S1")
        #expect(shared.lastSeq(for: "S1") == 0)
    }
}

/// The keys and the handle in the shared Keychain (a memory store stands in for it).
@Suite struct PushKeychainTests {
    @Test func aKeyIsMadeOnceAndKept() throws {
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        #expect(keychain.key(for: "S1") == nil)
        let first = try keychain.keyCreating(for: "S1")
        let again = try keychain.keyCreating(for: "S1")
        #expect(first.withUnsafeBytes { Data($0) } == again.withUnsafeBytes { Data($0) })
        #expect(first.bitCount == 256)
        let other = try keychain.keyCreating(for: "S2")
        #expect(other.withUnsafeBytes { Data($0) } != first.withUnsafeBytes { Data($0) })
        #expect(keychain.serverRefs() == ["S1", "S2"])
        #expect(keychain.allKeys().map(\.serverRef) == ["S1", "S2"])
        keychain.deleteKey(for: "S1")
        #expect(keychain.serverRefs() == ["S2"])
    }

    @Test func aKeyOfTheWrongSizeIsNoKey() throws {
        let secrets = MemoryPushSecrets()
        try secrets.save(Data(repeating: 1, count: 5), account: PushKeychain.keyPrefix + "S1")
        let keychain = PushKeychain(secrets: secrets)
        #expect(keychain.key(for: "S1") == nil)
        #expect(keychain.allKeys().isEmpty)
    }

    @Test func aKeychainThatRefusesIsAnErrorNotAKey() {
        let secrets = MemoryPushSecrets()
        secrets.failure = PushSecretsError(status: -34018)
        #expect(throws: PushSecretsError.self) { try PushKeychain(secrets: secrets).keyCreating(for: "S1") }
    }

    @Test func theRegistrationIsWholeOrNothing() throws {
        let secrets = MemoryPushSecrets()
        let keychain = PushKeychain(secrets: secrets)
        #expect(keychain.registration() == nil)
        #expect(keychain.handle == nil)
        let registration = PushRegistration(token: "ab12", env: "sandbox", handle: "h1")
        try keychain.save(registration)
        #expect(keychain.registration() == registration)
        #expect(keychain.handle == "h1")
        #expect(keychain.registeredAt != nil)
        try secrets.save(nil, account: PushKeychain.tokenAccount)
        #expect(keychain.registration() == nil)
        keychain.clearRegistration()
        #expect(keychain.handle == nil)
    }
}

/// While a push is shown and the app is in the background, a repeat of the same event is not made.
@MainActor
@Suite struct PushDedupeTests {
    private func failure(seq: Int64) -> Event {
        Event(seq: seq, agentId: "ios-demo-1", ts: 0, body: .error(message: "boom"))
    }

    @Test func anEventUpToTheOneAPushShowedMakesNoLocalNotice() async {
        let server = await IOSDemo.start()
        let system = RecordingSink()
        let notifications = IOSNotifications(postingTo: system)
        notifications.source = StaticNotificationSource(servers: [server])
        var seen: Int64 = 20
        notifications.pushSeq = { _ in seen }
        notifications.ingest(failure(seq: 19), from: server)
        notifications.ingest(failure(seq: 20), from: server)
        #expect(system.posted.isEmpty)
        // The cursor moved as always.
        #expect(notifications.cursor.seq(for: server.id) >= 20)
        notifications.ingest(failure(seq: 21), from: server)
        #expect(system.posted.count == 1)
        seen = 0
        notifications.ingest(failure(seq: 22), from: server)
        #expect(system.posted.count == 2)
    }
}
