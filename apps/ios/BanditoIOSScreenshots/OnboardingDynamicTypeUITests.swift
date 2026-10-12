import XCTest

/// The onboarding at the accessibility text sizes: every control of the three steps stays on the screen (the page scrolls
/// to reach the ones below the fold), and nothing is cut off at the sides. Run at the first accessibility size and at the
/// largest one.
@MainActor
final class OnboardingDynamicTypeUITests: XCTestCase {
    private func launchOnboarding(size: String, step: String? = nil, card: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        var arguments = ["-onboarding", "-AppleLanguages", "(en)", "-UIPreferredContentSizeCategoryName", size]
        if let step {
            arguments += ["-onboarding-step", step]
        }
        if let card {
            arguments += ["-onboarding-card", String(card)]
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Scrolls up until the element lies wholly on the screen (at most a few swipes), then checks it.
    private func assertOnScreen(_ element: XCUIElement, in app: XCUIApplication, _ what: String) {
        let screen = app.windows.firstMatch.frame
        var swipes = 0
        while (!element.isHittable || element.frame.maxY > screen.maxY || element.frame.minY < screen.minY) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "\(what) can be reached at this text size")
        XCTAssertGreaterThanOrEqual(element.frame.minX, screen.minX - 0.5, "\(what) is not cut on the left")
        XCTAssertLessThanOrEqual(element.frame.maxX, screen.maxX + 0.5, "\(what) is not cut on the right")
        XCTAssertLessThanOrEqual(element.frame.maxY, screen.maxY + 0.5, "\(what) is not below the screen")
    }

    private func checkWelcome(size: String) {
        continueAfterFailure = false
        let app = launchOnboarding(size: size)
        let start = app.buttons["onboarding.welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the welcome step opens at \(size)")
        assertOnScreen(start, in: app, "Let's go")
        assertOnScreen(app.buttons["onboarding.welcome.haveServer"], in: app, "I already have a server")
        app.terminate()
    }

    private func checkFeatures(size: String, card: Int) {
        continueAfterFailure = false
        let app = launchOnboarding(size: size, step: "features", card: card)
        let next = app.buttons["onboarding.features.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 15), "the cards open at \(size), card \(card)")
        assertOnScreen(next, in: app, "Next")
        assertOnScreen(app.buttons["onboarding.features.skip"], in: app, "Skip")
        app.terminate()
    }

    private func checkConnect(size: String) {
        continueAfterFailure = false
        let app = launchOnboarding(size: size, step: "connect")
        let scan = app.buttons["onboarding.connect.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15), "the connect step opens at \(size)")
        assertOnScreen(scan, in: app, "Scan the code")
        assertOnScreen(app.buttons["onboarding.connect.paste"], in: app, "Paste a link")
        assertOnScreen(app.buttons["onboarding.connect.type"], in: app, "Type an address")
        app.terminate()
    }

    func testAccessibilityMSizeKeepsEveryStepOnScreen() {
        let size = "UICTContentSizeCategoryAccessibilityM"
        checkWelcome(size: size)
        checkFeatures(size: size, card: 0)
        checkFeatures(size: size, card: 1)
        checkFeatures(size: size, card: 2)
        checkConnect(size: size)
    }

    func testLargestAccessibilitySizeKeepsEveryStepOnScreen() {
        let size = "UICTContentSizeCategoryAccessibilityXXXL"
        checkWelcome(size: size)
        checkFeatures(size: size, card: 0)
        checkFeatures(size: size, card: 1)
        checkFeatures(size: size, card: 2)
        checkConnect(size: size)
    }
}
