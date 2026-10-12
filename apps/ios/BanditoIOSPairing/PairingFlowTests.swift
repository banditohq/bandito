import XCTest

/// The connect flow of the iPhone app against a fake daemon (TLS on loopback of the Simulator): typing an address, the
/// fingerprint check, the name, and the loud failure for a server that is not the pinned one. Run in English.
final class PairingFlowTests: XCTestCase {
    private var daemon: FakeDaemon?
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // A fresh start: no saved servers (the app wipes them at launch).
        app.launchArguments = ["-resetServers", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    override func tearDown() {
        daemon?.stop()
        daemon = nil
    }

    private func openTypedForm() {
        app.launch()
        // The first run: "I already have a server", then "Type an address" opens the connect sheet on the form.
        let haveServer = app.buttons["onboarding.welcome.haveServer"]
        XCTAssertTrue(haveServer.waitForExistence(timeout: 15), "the onboarding starts")
        haveServer.tap()
        let type = app.buttons["onboarding.connect.type"]
        XCTAssertTrue(type.waitForExistence(timeout: 10))
        type.tap()
        XCTAssertTrue(app.textFields["connect.manual.address"].waitForExistence(timeout: 10), "the sheet opens on the typed form")
    }

    private func type(_ text: String, into id: String) {
        let field = app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 5), id)
        field.tap()
        field.typeText(text)
    }

    func testTypedAddressWithFingerprintPairsAndKeepsTheServer() throws {
        let daemon = try FakeDaemon()
        self.daemon = daemon
        openTypedForm()
        type(daemon.address, into: "connect.manual.address")
        type(FakeDaemon.validCode, into: "connect.manual.code")
        type(FakeDaemon.fingerprintA, into: "connect.manual.fingerprint")
        app.buttons["connect.manual.submit"].tap()
        XCTAssertTrue(app.staticTexts["connect.done.title"].waitForExistence(timeout: 20), "connected")
        XCTAssertEqual(daemon.redeems, 1)
        let name = app.textFields["connect.done.name"]
        XCTAssertTrue(name.exists)
        name.tap()
        name.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText("Studio")
        app.buttons["connect.done.action"].tap()
        // The reason for notifications comes after the first server; the onboarding is gone and the Crew has its server.
        let later = app.buttons["notifications.ask.later"]
        if later.waitForExistence(timeout: 10) { later.tap() }
        XCTAssertFalse(app.buttons["onboarding.welcome.haveServer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.tabBars.buttons.firstMatch.waitForExistence(timeout: 10))
    }

    func testTypedAddressWithoutFingerprintAsksToCompareFirst() throws {
        let daemon = try FakeDaemon()
        self.daemon = daemon
        openTypedForm()
        type(daemon.address, into: "connect.manual.address")
        type(FakeDaemon.validCode, into: "connect.manual.code")
        app.buttons["connect.manual.submit"].tap()
        let confirm = app.buttons["connect.trust.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "the fingerprint is shown to compare")
        XCTAssertEqual(daemon.redeems, 0, "the code is not sent before the person confirms")
        let shown = app.descendants(matching: .any).matching(identifier: "connect.trust.fingerprint").firstMatch
        XCTAssertTrue(shown.exists, "the fingerprint is on the screen")
        XCTAssertTrue(shown.label.uppercased().contains(String(FakeDaemon.fingerprintA.uppercased().prefix(2))))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["connect.done.title"].waitForExistence(timeout: 20))
        XCTAssertEqual(daemon.redeems, 1)
    }

    func testAnotherCertificateIsTheLoudFailureAndTheCodeIsNotSent() throws {
        let impostor = try FakeDaemon(certificate: .b)
        self.daemon = impostor
        openTypedForm()
        type(impostor.address, into: "connect.manual.address")
        type(FakeDaemon.validCode, into: "connect.manual.code")
        // The fingerprint the person trusts is the real server's, not the one this address presents.
        type(FakeDaemon.fingerprintA, into: "connect.manual.fingerprint")
        app.buttons["connect.manual.submit"].tap()
        XCTAssertTrue(app.staticTexts["This is not the server you paired"].waitForExistence(timeout: 20))
        XCTAssertEqual(impostor.redeems, 0, "the one-time code stayed on the phone")
    }

    func testAWrongCodeIsExplainedAndTheFormComesBack() throws {
        let daemon = try FakeDaemon()
        self.daemon = daemon
        openTypedForm()
        type(daemon.address, into: "connect.manual.address")
        type("wrong wrong wrong wrong wrong wrong", into: "connect.manual.code")
        type(FakeDaemon.fingerprintA, into: "connect.manual.fingerprint")
        app.buttons["connect.manual.submit"].tap()
        XCTAssertTrue(app.staticTexts["connect.error"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["connect.error"].label.contains("did not accept the code"))
        app.buttons["connect.tryAgain"].tap()
        XCTAssertTrue(app.textFields["connect.manual.address"].waitForExistence(timeout: 5))
    }

    func testNothingListeningSaysWhatToCheck() throws {
        openTypedForm()
        type("127.0.0.1:1", into: "connect.manual.address")
        type(FakeDaemon.validCode, into: "connect.manual.code")
        type(FakeDaemon.fingerprintA, into: "connect.manual.fingerprint")
        app.buttons["connect.manual.submit"].tap()
        XCTAssertTrue(app.staticTexts["connect.error"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["connect.error"].label.contains("Tailscale"))
    }
}
