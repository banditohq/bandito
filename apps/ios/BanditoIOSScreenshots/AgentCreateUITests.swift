import XCTest

/// Creating agents in the demo: "+" in Crew opens the sheet, "One agent" takes a name and Create, and the agent is in
/// the Crew list after. The card opens from the row's context menu.
@MainActor
final class AgentCreateUITests: XCTestCase {
    func testCreatingOneAgentShowsItInCrew() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-demo", "-tab", "crew", "-AppleLanguages", "(en)"]
        app.launch()

        let add = app.buttons["crew.new"]
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        add.tap()

        let oneAgent = app.segmentedControls.buttons["One agent"]
        XCTAssertTrue(oneAgent.waitForExistence(timeout: 10))
        oneAgent.tap()

        let name = app.textFields["oneAgent.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Ledger")
        // The keyboard is put away before the form is scrolled to Create: the Done key of the role field does it, and the
        // wait ends as soon as the keyboard is gone (no fixed pause).
        let role = app.textFields["oneAgent.role"]
        role.tap()
        role.typeText("\n")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 10)

        // Create sits at the foot of the form: scroll to it. It waits for the server's agents folder to be known.
        let create = app.buttons["oneAgent.create"]
        scroll(to: create, in: app)
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: create)
        waitForExpectations(timeout: 15)
        create.tap()

        XCTAssertTrue(app.staticTexts["Ledger"].waitForExistence(timeout: 15))
    }

    func testTheCardOpensFromTheContextMenu() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-demo", "-tab", "crew", "-AppleLanguages", "(en)"]
        app.launch()

        // "Forge" is in the "Waiting for you" card and in the team's row: the row is the last of them.
        let forges = app.staticTexts.matching(NSPredicate(format: "label == %@", "Forge"))
        XCTAssertTrue(forges.element(boundBy: 0).waitForExistence(timeout: 20))
        forges.element(boundBy: forges.count - 1).press(forDuration: 1.0)

        let details = app.buttons["Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()

        XCTAssertTrue(app.textFields["agent.detail.name"].waitForExistence(timeout: 10))
    }

    func testTheOneAgentFormShowsItsFields() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-demo", "-tab", "crew", "-new-agent", "one", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.textFields["oneAgent.name"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.textFields["oneAgent.role"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["oneAgent.runtime"].exists)
        XCTAssertTrue(app.staticTexts["Ask for permission"].exists || app.staticTexts["Only the risky ones"].exists)
        scroll(to: app.buttons["oneAgent.create"], in: app)
    }

    func testAReadyTeamPreviewListsItsAgents() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-demo", "-tab", "crew", "-new-agent", "-AppleLanguages", "(en)"]
        app.launch()

        let team = app.staticTexts["Web project"]
        XCTAssertTrue(team.waitForExistence(timeout: 20))
        team.tap()

        XCTAssertTrue(app.staticTexts["Web developer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Code reviewer"].exists)
        scroll(to: app.buttons["newAgent.team.create"], in: app)
    }

    /// Swipes the screen up until `element` is on it (a list builds its far rows only when they are near).
    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 10))
    }
}
