import XCTest

/// Pictures of step 4 (`s4-<screen>-<appearance>-<language>`): the first run to a connected server (onboarding, the
/// connect sheet on the form, the reason for notifications, the Crew with the server's team), Settings → Servers, and
/// the confirmation of a scanned code. The server is the fake TLS daemon.
final class PairingS4ScreenshotTests: XCTestCase {
    private var daemon: FakeDaemon?

    override func setUpWithError() throws { continueAfterFailure = true }

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
        Thread.sleep(forTimeInterval: 1.2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "s4-\(name)-\(appearance)-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func type(_ app: XCUIApplication, _ text: String, into id: String) {
        let field = app.textFields[id]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText(text)
        }
    }

    func testFirstRunDarkEnglish() throws { try firstRun(.dark, "dark", "en") }
    func testFirstRunDarkRussian() throws { try firstRun(.dark, "dark", "ru") }
    func testFirstRunLightRussian() throws { try firstRun(.light, "light", "ru") }

    private func firstRun(_ style: XCUIDevice.Appearance, _ appearance: String, _ language: String) throws {
        XCUIDevice.shared.appearance = style
        let daemon = try FakeDaemon()
        self.daemon = daemon
        // A scanned code asks first.
        var app = launch(["-pairLink", Self.link, "-pairLinkScanned"], language: language)
        shoot("scan-confirm", appearance, language)
        app.terminate()
        // The first run: the last step of the onboarding, the form, the answer, the notifications, the Crew, Settings.
        app = launch([], language: language)
        let haveServer = app.buttons["onboarding.welcome.haveServer"]
        if haveServer.waitForExistence(timeout: 15) { haveServer.tap() }
        _ = app.buttons["onboarding.connect.type"].waitForExistence(timeout: 10)
        shoot("onboarding-connect", appearance, language)
        app.buttons["onboarding.connect.type"].tap()
        _ = app.textFields["connect.manual.address"].waitForExistence(timeout: 10)
        type(app, daemon.address, into: "connect.manual.address")
        type(app, FakeDaemon.validCode, into: "connect.manual.code")
        app.buttons["connect.manual.submit"].tap()
        _ = app.buttons["connect.trust.confirm"].waitForExistence(timeout: 20)
        app.buttons["connect.trust.confirm"].tap()
        _ = app.staticTexts["connect.done.title"].waitForExistence(timeout: 20)
        shoot("done", appearance, language)
        app.buttons["connect.done.action"].tap()
        _ = app.buttons["notifications.ask.later"].waitForExistence(timeout: 10)
        shoot("notifications-ask", appearance, language)
        app.buttons["notifications.ask.later"].tap()
        Thread.sleep(forTimeInterval: 3)
        shoot("crew", appearance, language)
        let tabs = app.tabBars.buttons
        if tabs.count >= 4 { tabs.element(boundBy: 3).tap() }
        shoot("settings-servers", appearance, language)
        app.terminate()
    }
}
