import BanditoKit
import Foundation
import Testing
import UserNotifications

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// Which delivered notices go when a chat is read to a seq on another device (`IOSNotificationSink.clearsWhenRead`).
@Suite struct ReadElsewhereNoticeTests {
    private let server = UUID()
    private let agent = "forge"

    /// A notice of this chat, as the app posts it: identifier `<server>:<seq>`, the agent as its thread.
    private func clears(
        identifier: String? = nil, category: String = NotificationContent.finishedCategory,
        info: [AnyHashable: Any] = [:], thread: String? = nil, serverID: UUID? = nil, mark: Int64
    ) -> Bool {
        IOSNotificationSink.clearsWhenRead(
            identifier: identifier ?? "\(server.uuidString):5", threadID: thread ?? agent, categoryID: category,
            userInfo: info, agentID: agent, serverID: serverID ?? server, readSeq: mark)
    }

    @Test func theRepliesUpToTheMarkGo() {
        #expect(clears(info: ["agentID": agent, "server": server.uuidString], mark: 5))
        #expect(clears(mark: 9), "a mark past the notice clears it too")
        #expect(clears(category: NotificationContent.failedCategory, mark: 5))
    }

    @Test func aNoticePastTheMarkStays() {
        #expect(!clears(identifier: "\(server.uuidString):6", mark: 5))
    }

    @Test func aNoticeWhoseSeqCannotBeReadStays() {
        #expect(!clears(identifier: "no-seq-here", mark: 5))
        #expect(!clears(identifier: "\(server.uuidString):", mark: 5))
        #expect(!clears(identifier: "\(server.uuidString):x", mark: 5))
        #expect(IOSNotificationSink.noticeSeq("\(server.uuidString):41") == 41)
        #expect(IOSNotificationSink.noticeSeq("ap-1") == nil)
    }

    @Test func noticesThatWaitForAnAnswerStay() {
        for category in [
            NotificationContent.approvalCategory, NotificationContent.approvalReviewCategory,
            PhoneNotice.riskyCategory, NotificationContent.formCategory, NotificationContent.questionCategory,
        ] {
            #expect(!clears(category: category, mark: 9), "\(category) waits for an answer")
        }
        #expect(!clears(info: ["approvalID": "ap1"], mark: 9))
        #expect(!clears(info: ["formID": "f1"], mark: 9))
    }

    @Test func anotherChatOrAnotherServerStays() {
        #expect(!clears(thread: "other", mark: 9))
        #expect(!clears(info: ["server": UUID().uuidString], mark: 9))
    }

    @Test func aPushNamesTheServerByItsRefAndStillClears() {
        // A push's notice carries the phone's name for the server, and its identifier uses that name.
        #expect(clears(identifier: "S1:3", info: ["server": "S1"], mark: 5))
    }
}
