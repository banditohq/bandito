import XCTest

/// The first run on the simulator: "Let's go" leads through the three cards to the connect step, Back works from there,
/// "I already have a server" skips to the connect step, and "Allow" on the approval card reacts and asks again.
@MainActor
final class OnboardingUITests: XCTestCase {
    private func launchOnboarding(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-onboarding", "-AppleLanguages", "(en)"] + extra
        app.launch()
        return app
    }

    func testLetsGoWalksThroughTheCardsToTheConnectStep() {
        continueAfterFailure = false
        let app = launchOnboarding()

        let start = app.buttons["onboarding.welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the welcome step is the first screen")
        start.tap()

        let next = app.buttons["onboarding.features.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Let's go opens the cards")
        next.tap()
        next.tap()
        next.tap()

        XCTAssertTrue(app.buttons["onboarding.connect.scan"].waitForExistence(timeout: 5), "the last card leads to connect")
        XCTAssertTrue(app.buttons["onboarding.connect.paste"].exists)
        XCTAssertTrue(app.buttons["onboarding.connect.type"].exists)

        app.buttons["Back"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Back from connect returns to the last card")
        app.terminate()
    }

    func testIHaveAServerSkipsToConnect() {
        continueAfterFailure = false
        let app = launchOnboarding()

        let skip = app.buttons["onboarding.welcome.haveServer"]
        XCTAssertTrue(skip.waitForExistence(timeout: 15))
        skip.tap()
        XCTAssertTrue(app.buttons["onboarding.connect.scan"].waitForExistence(timeout: 5), "the link goes to connect")
        app.terminate()
    }

    func testChoosingAWayOpensTheConnectSheet() {
        continueAfterFailure = false
        let app = launchOnboarding(["-onboarding-step", "connect"])

        let scan = app.buttons["onboarding.connect.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        // The Simulator has no camera: the sheet still opens, with the other two ways in.
        XCTAssertTrue(app.buttons["connect.manualButton"].waitForExistence(timeout: 10), "the way opens the connect sheet")
        app.terminate()
    }

    func testAllowReactsAndAsksAgain() {
        continueAfterFailure = false
        let app = launchOnboarding(["-onboarding-step", "features", "-onboarding-card", "1"])

        let allow = app.buttons["Approve"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "the approval card waits for the person")
        allow.tap()
        XCTAssertTrue(app.buttons["Allowed"].waitForExistence(timeout: 2), "Allow turns the card into a check")
        XCTAssertTrue(app.buttons["Approve"].waitForExistence(timeout: 5), "after two seconds it asks again")
        app.terminate()
    }
}
