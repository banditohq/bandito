@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The join code's branch of the connect wizard: an account that can sign a phone in starts on the join code, and the
/// phone access is turned on in the background on the servers that can take it (none, one, or two; a failure is kept
/// for "Try again").
@MainActor
@Suite struct PhoneAccessWarmupTests {
    /// A server whose cloud is off, as it is before the wizard turns it on.
    func offServer(_ name: String) -> WizardServer {
        let server = WizardServer(name: name)
        server.status = RelayStatus(enabled: false, connected: false, sid: "")
        return server
    }

    /// The same enable the wizard makes: the controller of the server, the account's registrar.
    func warmup() -> PhoneAccessWarmup {
        PhoneAccessWarmup { server in
            let controller = RelayController(
                host: server, registrar: { WizardRegistrar() }, connectTimeout: .milliseconds(300),
                pollInterval: .milliseconds(10))
            return await controller.enable()
        }
    }

    /// Waits until the summary is what the check wants, or gives up.
    func settle(_ warmup: PhoneAccessWarmup, until check: (PhoneAccessWarmup.Summary) -> Bool) async -> Bool {
        for _ in 0..<300 {
            if check(warmup.summary) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func theAccountDecidesTheFirstPath() {
        #expect(PhoneWizardPath.path(accountReady: true) == .joinFirst)
        #expect(PhoneWizardPath.path(accountReady: false) == .pairCode)
    }

    @Test func noServerMeansNoLineAndNoWork() {
        let warmup = warmup()
        warmup.start([])
        #expect(warmup.summary == .noServers)
        #expect(warmup.rows.isEmpty)
    }

    @Test func aServerThatIsNotConnectedIsLeftOut() {
        let server = offServer("home")
        server.isConnected = false
        let warmup = warmup()
        warmup.start([server])
        #expect(warmup.summary == .noServers)
        #expect(server.enableCalls == 0)
    }

    @Test func oneServerWithTheAccessOffIsTurnedOn() async {
        let server = offServer("home")
        let warmup = warmup()
        warmup.start([server])
        // Before the answer the line says it is being turned on.
        #expect(warmup.summary == .enabling)
        #expect(await settle(warmup) { $0 == .ready(["home"]) })
        #expect(server.enableCalls == 1)
    }

    @Test func twoServersAreTurnedOnInTheirOrder() async {
        let home = offServer("home")
        let myHome = offServer("my-home")
        let warmup = warmup()
        warmup.start([home, myHome])
        #expect(await settle(warmup) { $0 == .ready(["home", "my-home"]) })
        #expect(home.enableCalls == 1)
        #expect(myHome.enableCalls == 1)
    }

    @Test func aServerThatIsOnAlreadyAnswersWithoutAnEnable() async {
        let server = WizardServer(name: "home")
        let warmup = warmup()
        warmup.start([server])
        #expect(await settle(warmup) { $0 == .ready(["home"]) })
        #expect(server.enableCalls == 0)
    }

    @Test func aFailedServerIsNamedAndTryAgainAsksOnlyIt() async {
        let home = offServer("home")
        let broken = offServer("my-home")
        broken.enableFails = true
        let warmup = warmup()
        warmup.start([home, broken])
        #expect(await settle(warmup) { $0 == .failed(["my-home"]) })
        // The server that worked keeps its state; the broken one is asked again.
        broken.enableFails = false
        warmup.retry()
        #expect(await settle(warmup) { $0 == .ready(["home", "my-home"]) })
        #expect(home.enableCalls == 1)
        #expect(broken.enableCalls == 2)
    }

    @Test func everyServerFailingNamesThemAll() async {
        let first = offServer("home")
        first.enableFails = true
        let second = offServer("my-home")
        second.enableFails = true
        let warmup = warmup()
        warmup.start([first, second])
        #expect(await settle(warmup) { $0 == .failed(["home", "my-home"]) })
    }
}
