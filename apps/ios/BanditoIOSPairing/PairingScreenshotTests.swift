import XCTest

/// Pictures of the connect flow, dark and light, English and Russian, kept as attachments of the test result
/// (`s3-<screen>-<appearance>-<language>`). The camera states and a link from outside come from launch arguments that
/// only debug builds read (`PairingLaunchHooks`); the typed flow runs against the fake daemon.
final class PairingScreenshotTests: XCTestCase {
    private var daemon: FakeDaemon?

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    override func tearDown() {
        daemon?.stop()
        daemon = nil
    }

    private static let link =
        "bandito://pair?v=1&code=otter-lava-mint-orbit-crane-fig&fp=\(String(repeating: "ab", count: 32))&name=Studio%20Mac&host=100.101.102.103:7879&host=192.168.1.5:7879"

    private func launch(_ arguments: [String], language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-resetServers", "-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"] + arguments
        app.launch()
        return app
    }

    private func shoot(_ name: String, _ appearance: String, _ language: String) {
        // Let a sheet finish sliding and a keyboard finish rising.
        Thread.sleep(forTimeInterval: 1.2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "s3-\(name)-\(appearance)-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openManual(_ app: XCUIApplication) {
        let button = app.buttons["connect.manualButton"]
        if button.waitForExistence(timeout: 15) { button.tap() }
    }

    private func type(_ app: XCUIApplication, _ text: String, into id: String) {
        let field = app.textFields[id]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText(text)
        }
    }

    func testDarkEnglish() throws { try screens(.dark, "dark", "en") }
    func testDarkRussian() throws { try screens(.dark, "dark", "ru") }
    func testLightEnglish() throws { try screens(.light, "light", "en") }
    func testLightRussian() throws { try screens(.light, "light", "ru") }

    private func screens(_ style: XCUIDevice.Appearance, _ appearance: String, _ language: String) throws {
        XCUIDevice.shared.appearance = style
        // The welcome screen, then the three camera states of the scanner.
        var app = launch([], language: language)
        shoot("welcome", appearance, language)
        app.terminate()
        for state in ["notAsked", "denied", "unavailable"] {
            app = launch(["-openConnect", "-pairCamera", state], language: language)
            shoot("camera-\(state)", appearance, language)
            app.terminate()
        }
        // A link from outside waits for the person.
        app = launch(["-pairLink", Self.link], language: language)
        shoot("confirm-link", appearance, language)
        app.terminate()
        // An unreadable link.
        app = launch(["-pairLink", "bandito://pair?v=2&code=x"], language: language)
        shoot("error-update", appearance, language)
        app.terminate()
        // The typed form, empty and then the flow against the fake daemon.
        app = launch(["-openConnect", "-pairCamera", "unavailable"], language: language)
        openManual(app)
        _ = app.textFields["connect.manual.address"].waitForExistence(timeout: 5)
        shoot("manual", appearance, language)
        let daemon = try FakeDaemon()
        self.daemon = daemon
        type(app, daemon.address, into: "connect.manual.address")
        type(app, FakeDaemon.validCode, into: "connect.manual.code")
        app.buttons["connect.manual.submit"].tap()
        _ = app.buttons["connect.trust.confirm"].waitForExistence(timeout: 20)
        shoot("trust", appearance, language)
        app.buttons["connect.trust.confirm"].tap()
        _ = app.staticTexts["connect.done.title"].waitForExistence(timeout: 20)
        shoot("done", appearance, language)
        app.terminate()
        daemon.stop()
        // The loud failure: the address shows another certificate than the pinned one.
        let impostor = try FakeDaemon(certificate: .b)
        self.daemon = impostor
        app = launch(["-openConnect", "-pairCamera", "unavailable"], language: language)
        openManual(app)
        type(app, impostor.address, into: "connect.manual.address")
        type(app, FakeDaemon.validCode, into: "connect.manual.code")
        type(app, FakeDaemon.fingerprintA, into: "connect.manual.fingerprint")
        app.buttons["connect.manual.submit"].tap()
        _ = app.buttons["connect.tryAgain"].waitForExistence(timeout: 20)
        shoot("error-mismatch", appearance, language)
        app.terminate()
        impostor.stop()
        // Nothing listening.
        app = launch(["-openConnect", "-pairCamera", "unavailable"], language: language)
        openManual(app)
        type(app, "127.0.0.1:1", into: "connect.manual.address")
        type(app, FakeDaemon.validCode, into: "connect.manual.code")
        type(app, FakeDaemon.fingerprintA, into: "connect.manual.fingerprint")
        app.buttons["connect.manual.submit"].tap()
        _ = app.buttons["connect.tryAgain"].waitForExistence(timeout: 30)
        shoot("error-unreachable", appearance, language)
        app.terminate()
    }
}
