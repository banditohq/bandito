import XCTest

/// The chat on the simulator, in the demo: open Forge, write a message, wait for the streamed reply, and allow a request.
@MainActor
final class ChatUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-demo", "-chat", "Forge", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    func testWriteWaitForTheReplyAndAllowARequest() {
        let app = launch()

        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the chat opens with its message box")
        field.tap()
        field.typeText("Look around the project")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled, "a typed message can be sent")
        send.tap()

        // The message is in the thread at once, in a bubble of the person.
        let mine = app.cells.matching(NSPredicate(format: "label CONTAINS 'Look around the project'")).firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "the message shows in the thread")

        // The agent works (commands fold into one line), streams its reply, and the reply is a message.
        let reply = app.cells.matching(NSPredicate(format: "label CONTAINS 'retries'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 40), "the reply arrives")

        // The ordinary request is allowed from its card in the chat; the card gives way to a line.
        let allow = app.buttons["chat.approval.allow.ios-demo-approval-2"]
        // The request is a few screens above the new messages: scroll up until its card is built.
        let list = app.collectionViews["chat.list"]
        // Plain swipes (a fast one flies past the card), letting each settle before looking.
        var swipes = 0
        while !allow.waitForExistence(timeout: 1.5), swipes < 12 {
            list.swipeDown()
            swipes += 1
        }
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "the request waits in the chat")
        allow.tap()
        XCTAssertTrue(allow.waitForNonExistence(timeout: 10), "the allowed request leaves its card")
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'swift test -q' AND label CONTAINS 'Allowed'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the answer stays as a line")
        app.terminate()
    }

    func testARequestTheAgentMakesDuringATurnIsAllowedInTheChat() {
        let app = launch()
        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Run the tests")
        app.buttons["chat.send"].tap()
        let allow = app.buttons["chat.approval.allow.demo-script-approval-1"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "the agent asks before it runs the tests")
        allow.tap()
        let reply = app.cells.matching(NSPredicate(format: "label CONTAINS 'retries'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 40), "the turn goes on after the answer")
        app.terminate()
    }
}
