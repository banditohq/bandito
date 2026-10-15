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

    /// Writes the screen as a PNG into the folder named by `BANDITO_SHOTS_DIR` (xcodebuild's `TEST_RUNNER_` prefix passes it in);
    /// nothing is written without it.
    private func shoot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["BANDITO_SHOTS_DIR"], !folder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// The palette's button for `emoji` (the lifted message holds a label with the same emoji: only a button is the menu's).
    private func reactionButton(_ app: XCUIApplication, _ emoji: String) -> XCUIElement {
        let button = app.buttons[emoji].firstMatch
        return button.exists ? button : app.menuItems[emoji].firstMatch
    }

    /// A long press lifts the message with a row of reactions over the menu; a reaction shows under the message and the same
    /// one again takes it off; Reply puts a quote above the box, and the send takes it away.
    func testLongPressGivesReactionsAndReply() {
        let app = launch()
        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the chat opens")
        let message = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Forge:' AND NOT label CONTAINS '🔥'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 20), "an agent's message is in the thread")
        let words = String(message.label.dropFirst("Forge: ".count).prefix(24))
        message.press(forDuration: 1.2)
        let fire = reactionButton(app, "🔥")
        XCTAssertTrue(fire.waitForExistence(timeout: 5), "the menu has the reactions")
        shoot("menu-with-reactions")
        let reply = app.buttons["Reply"].firstMatch
        XCTAssertTrue(reply.exists, "the menu has Reply")
        XCTAssertTrue(app.buttons["Copy"].firstMatch.exists, "the menu has Copy")
        XCTAssertTrue(app.buttons["Select text"].firstMatch.exists, "the menu has Select text")
        XCTAssertTrue(app.buttons["Share"].firstMatch.exists, "the menu has Share")
        fire.tap()
        let reacted = app.cells.matching(NSPredicate(format: "label CONTAINS '🔥' AND label CONTAINS %@", words)).firstMatch
        XCTAssertTrue(reacted.waitForExistence(timeout: 10), "the reaction shows under the message")
        shoot("reaction-under-message")

        // The same reaction again takes it off.
        reacted.press(forDuration: 1.2)
        let again = reactionButton(app, "🔥")
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        shoot("menu-own-reaction-lit")
        again.tap()
        let off = app.cells.matching(NSPredicate(format: "label CONTAINS '🔥'")).firstMatch
        XCTAssertTrue(off.waitForNonExistence(timeout: 10), "the reaction is taken off")

        // Reply: the quote is above the box; the answer carries it.
        let target = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Forge:'")).firstMatch
        target.press(forDuration: 1.2)
        let replyButton = app.buttons["Reply"].firstMatch
        XCTAssertTrue(replyButton.waitForExistence(timeout: 5))
        replyButton.tap()
        XCTAssertTrue(app.otherElements["chat.reply"].waitForExistence(timeout: 5), "the quote is above the box")
        field.typeText("Good, do it")
        shoot("reply-above-the-box")
        app.buttons["chat.send"].tap()
        // (The demo daemon's echo of a message has no `seq`, so the quote of an answer is checked in the unit tests, where
        // the events carry one.)
        let sent = app.cells.matching(NSPredicate(format: "label CONTAINS 'Good, do it'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "the answer is in the thread")
        XCTAssertFalse(app.otherElements["chat.reply"].exists, "the quote above the box is gone after the send")
        shoot("reply-sent")
        app.terminate()
    }
}
