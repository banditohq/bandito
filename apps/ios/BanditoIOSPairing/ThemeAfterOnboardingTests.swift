import XCTest

/// The theme setting keeps ruling the app after the onboarding is gone: with the dark theme, the Crew that opens when the
/// first server is connected is dark, and with the light theme it is light, with no restart in between.
final class ThemeAfterOnboardingTests: XCTestCase {
    private var daemon: FakeDaemon?

    override func tearDown() {
        daemon?.stop()
        daemon = nil
    }

    /// How light the pixel at `point` (in points) of the screen is, 0 (black) to 1 (white).
    private func brightness(atX x: CGFloat, y: CGFloat) -> CGFloat {
        let shot = XCUIScreen.main.screenshot()
        guard let image = shot.image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        let scale = CGFloat(image.width) / XCUIScreen.main.screenshot().image.size.width
        let px = Int(x * scale), py = Int(y * scale)
        let offset = py * image.bytesPerRow + px * (image.bitsPerPixel / 8)
        let r = CGFloat(bytes[offset]), g = CGFloat(bytes[offset + 1]), b = CGFloat(bytes[offset + 2])
        return (r + g + b) / (3 * 255)
    }

    private func firstRunToCrew(theme: String) throws -> XCUIApplication {
        let daemon = try FakeDaemon()
        self.daemon = daemon
        let app = XCUIApplication()
        app.launchArguments = ["-ios.appearance.theme", theme, "-resetServers", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let haveServer = app.buttons["onboarding.welcome.haveServer"]
        XCTAssertTrue(haveServer.waitForExistence(timeout: 15))
        haveServer.tap()
        let type = app.buttons["onboarding.connect.type"]
        XCTAssertTrue(type.waitForExistence(timeout: 10))
        type.tap()
        let address = app.textFields["connect.manual.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(daemon.address)
        let code = app.textFields["connect.manual.code"]
        code.tap()
        code.typeText(FakeDaemon.validCode)
        let fingerprint = app.textFields["connect.manual.fingerprint"]
        fingerprint.tap()
        fingerprint.typeText(FakeDaemon.fingerprintA)
        app.buttons["connect.manual.submit"].tap()
        XCTAssertTrue(app.buttons["connect.done.action"].waitForExistence(timeout: 20))
        app.buttons["connect.done.action"].tap()
        let later = app.buttons["notifications.ask.later"]
        if later.waitForExistence(timeout: 10) { later.tap() }
        // The Crew is on screen: its tab bar, and the server's team.
        XCTAssertTrue(app.staticTexts["Forge"].waitForExistence(timeout: 20))
        return app
    }

    func testTheDarkThemeStaysDarkAfterTheOnboarding() throws {
        let app = try firstRunToCrew(theme: "dark")
        XCTAssertLessThan(brightness(atX: 8, y: 400), 0.3, "the Crew is dark")
        app.terminate()
    }

    func testTheLightThemeStaysLightAfterTheOnboarding() throws {
        let app = try firstRunToCrew(theme: "light")
        XCTAssertGreaterThan(brightness(atX: 8, y: 400), 0.7, "the Crew is light")
        app.terminate()
    }
}
