import XCTest

/// Screenshots of the Settings tab for the design review: the top and the bottom of the list, in Russian and in English.
/// The appearance is set on the simulator before the run. The screenshots are attachments of the result bundle, exported
/// with `xcresulttool`.
@MainActor
final class SettingsScreenshotTests: XCTestCase {
    func testRussian() {
        captureSettings(language: "ru")
    }

    func testEnglish() {
        captureSettings(language: "en")
    }

    private func captureSettings(language: String) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.bandito.ios")
        app.launchArguments = ["-demo", "-tab", "settings", "-AppleLanguages", "(\(language))"]
        app.launch()

        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        attach(named: "s2-settings-top-\(language)")

        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0..<8 {
            list.swipeUp()
        }
        attach(named: "s2-settings-bottom-\(language)")
        app.terminate()
    }

    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
