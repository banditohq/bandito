import XCTest

/// The Inbox on the simulator: a swipe to the right allows a plain approval, and its row leaves the list.
@MainActor
final class InboxUITests: XCTestCase {
    func testSwipeAllowRemovesTheRow() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-demo", "-tab", "inbox", "-AppleLanguages", "(en)"]
        app.launch()

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'swift test -q'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the ordinary approval is listed")
        row.swipeRight()
        let allow = app.buttons["Approve"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "the swipe shows Approve")
        allow.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "the allowed row leaves the Inbox")
        app.terminate()
    }
}
