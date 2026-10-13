import XCTest

/// The iPhone app against the real relay and a real daemon, for a person to run before a release. Skipped unless
/// `TEST_RUNNER_BANDITO_LIVE_DIR=<dir>` names a folder with `link.txt` (a pairing link of a daemon on relay.bandito.dev,
/// see `LiveRelayTests` in BanditoKit). Pictures go to `<dir>/shots`.
final class LiveRelayUITests: XCTestCase {
    private var dir: String? { ProcessInfo.processInfo.environment["BANDITO_LIVE_DIR"] }

    private func shoot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir {
            try? FileManager.default.createDirectory(atPath: dir + "/shots", withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir + "/shots/\(name).png"))
        }
    }

    func testPairThroughTheRealRelayAndSeeTheAgents() throws {
        guard let dir else { throw XCTSkip("BANDITO_LIVE_DIR is not set: a check for a person to run by hand") }
        let link = try String(contentsOfFile: dir + "/link.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let app = XCUIApplication()
        app.launchArguments = ["-resetServers", "-ios.appearance.theme", "dark", "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-pairLink", link, "-pairLinkScanned"]
        app.launch()
        XCTAssertTrue(app.buttons["connect.confirm"].waitForExistence(timeout: 20), "the link asks first")
        shoot("live-1-confirm-cloud")
        app.buttons["connect.confirm"].tap()
        XCTAssertTrue(app.staticTexts["connect.done.title"].waitForExistence(timeout: 40), "paired through the relay")
        XCTAssertTrue(app.staticTexts["connect.done.route"].exists, "the screen says how it is connected")
        shoot("live-2-connected-via-cloud")
        app.buttons["connect.done.action"].tap()
        if app.buttons["notifications.ask.later"].waitForExistence(timeout: 8) { app.buttons["notifications.ask.later"].tap() }
        XCTAssertTrue(app.staticTexts["Forge"].waitForExistence(timeout: 40), "the Crew shows the agent of the daemon")
        shoot("live-3-crew")
    }
}
