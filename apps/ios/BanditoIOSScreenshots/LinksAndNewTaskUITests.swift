import XCTest

/// `bandito://` links keep opening their place (the app has its own scene delegate for the icon's actions), and the
/// New task button sends a task that lands in the agent's chat.
@MainActor
final class LinksAndNewTaskUITests: XCTestCase {
    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-demo", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["newTask.button"].waitForExistence(timeout: 15), "the Crew is shown")
        return app
    }

    func testInboxLinkOpensTheInbox() {
        continueAfterFailure = false
        let app = launchDemo()
        app.open(URL(string: "bandito://inbox")!)
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'swift test -q'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the link switched to the Inbox")
        app.terminate()
    }

    func testNewTaskSendsAndOpensTheChat() {
        continueAfterFailure = false
        let app = launchDemo()
        app.buttons["newTask.button"].tap()
        let send = app.buttons["newTask.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "a short tap opens the sheet")
        XCTAssertFalse(send.isEnabled, "nothing to send yet")
        app.buttons["Scout"].firstMatch.tap()
        app.typeText("Summarise the release notes")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(send.waitForNonExistence(timeout: 5), "the sheet closes")
        let sent = app.cells.matching(NSPredicate(format: "label CONTAINS 'Summarise the release notes'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "the chat of the agent opens with the task")
        app.terminate()
    }

    func testLongPressOpensTheSheetAndTheNextTapStillWorks() {
        continueAfterFailure = false
        let app = launchDemo()
        let button = app.buttons["newTask.button"]
        button.press(forDuration: 1.0)
        let send = app.buttons["newTask.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "a long press opens the sheet")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(send.waitForNonExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(send.waitForExistence(timeout: 5), "the next short tap is not swallowed")
        app.terminate()
    }
}
