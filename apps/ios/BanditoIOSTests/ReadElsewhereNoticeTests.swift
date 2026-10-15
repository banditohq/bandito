import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// Which delivered notices go when a chat is read on another device (`IOSNotificationSink.clearsWhenRead`).
@Suite struct ReadElsewhereNoticeTests {
    private let server = UUID()

    @Test func theRepliesOfTheReadChatGo() {
        let info: [AnyHashable: Any] = ["agentID": "forge", "approvalID": "", "formID": "", "server": server.uuidString]
        #expect(
            IOSNotificationSink.clearsWhenRead(threadID: "forge", userInfo: info, agentID: "forge", serverID: server))
        // A notice that names no server belongs to the chat alone.
        #expect(
            IOSNotificationSink.clearsWhenRead(
                threadID: "forge", userInfo: ["agentID": "forge"], agentID: "forge", serverID: server))
    }

    @Test func anotherChatOrAnotherServerStays() {
        #expect(
            !IOSNotificationSink.clearsWhenRead(
                threadID: "other", userInfo: ["agentID": "other"], agentID: "forge", serverID: server))
        #expect(
            !IOSNotificationSink.clearsWhenRead(
                threadID: "forge", userInfo: ["server": UUID().uuidString], agentID: "forge", serverID: server))
    }

    @Test func anApprovalOrAQuestionWaitsForItsAnswer() {
        #expect(
            !IOSNotificationSink.clearsWhenRead(
                threadID: "forge", userInfo: ["approvalID": "ap1"], agentID: "forge", serverID: server))
        #expect(
            !IOSNotificationSink.clearsWhenRead(
                threadID: "forge", userInfo: ["formID": "f1"], agentID: "forge", serverID: server))
    }
}
