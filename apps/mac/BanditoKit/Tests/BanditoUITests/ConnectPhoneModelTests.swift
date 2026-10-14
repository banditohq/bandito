@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@MainActor
final class WizardServer: PhoneWizardServer {
    let wizardID = UUID()
    var wizardName: String
    var isConnected = true
    var canPair = true
    var relayName: String { wizardName }
    var supportsRelay = true
    var status = RelayStatus(enabled: true, connected: true, sid: "abcdefghijklmnopqrstuvwxyz")
    var devices: [Device] = [Device(id: "mac", name: "Mac", createdAt: 1, lastSeenAt: nil, current: true, platform: "macos")]
    var codes = 0
    var enableCalls = 0
    var codeLifetimeMs: Int64 = 600_000
    let link = PhonePairLink.make(
        code: "otter-lava-mint-orbit-crane-fig", fingerprint: nil, name: "Studio", hosts: [],
        relay: RelayRoute(host: "relay.bandito.dev", sid: "abcdefghijklmnopqrstuvwxyz"),
        noiseKey: Base64URL.encode(Data(repeating: 7, count: 32)))

    init(name: String) { wizardName = name }

    func relayStatus() async throws -> RelayStatus { status }
    func relayEnable(url: String, sid: String, secret: String) async throws -> RelayStatus {
        enableCalls += 1
        status = RelayStatus(enabled: true, connected: true, sid: sid)
        return status
    }
    func relayDisable() async throws -> RelayStatus { .off }
    func wizardPairCode() async throws -> PairCode {
        codes += 1
        return PairCode(code: "otter-lava-mint-orbit-crane-fig", expiresInMs: codeLifetimeMs, link: link)
    }
    var devicesFail = false
    func wizardDevices() async throws -> [Device] {
        if devicesFail { throw RPCError(code: RPCError.disconnected, message: "x") }
        return devices
    }
}

actor WizardRegistrar: RelayRegistrar {
    func registerRelayServer(name: String) async throws -> RelayRegistration {
        RelayRegistration(sid: "abcdefghijklmnopqrstuvwxyz", secret: "s", relayURL: "wss://relay.bandito.dev")
    }
    func relayServers() async throws -> [RelayServerEntry] { [] }
    func deleteRelayServer(sid: String) async throws {}
}

@MainActor
@Suite struct ConnectPhoneModelTests {
    /// Defaults of their own, so a test never writes the iPhone switch of the app's settings.
    static func scratchDefaults() -> UserDefaults {
        let name = "ConnectPhoneModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func model(_ servers: [WizardServer], signedIn: Bool = true) -> ConnectPhoneModel {
        ConnectPhoneModel(
            candidates: servers, pollInterval: .milliseconds(20), defaults: Self.scratchDefaults(),
            makeController: { server in
                RelayController(
                    host: server, registrar: { signedIn ? WizardRegistrar() : nil }, connectTimeout: .milliseconds(300),
                    pollInterval: .milliseconds(10))
            })
    }

    func wait(_ model: ConnectPhoneModel, until check: (ConnectPhoneModel.Step) -> Bool) async -> Bool {
        for _ in 0..<200 {
            if check(model.step) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func openingTheWizardTurnsTheIPhoneBlockOnWithOrWithoutAServer() {
        let withServer = Self.scratchDefaults()
        let made = ConnectPhoneModel(
            candidates: [WizardServer(name: "Studio")], pollInterval: .milliseconds(20), defaults: withServer,
            makeController: { server in RelayController(host: server, registrar: { nil }) })
        #expect(!withServer.bool(forKey: PhoneAccessRules.betaStorageKey), "off before the wizard opens")
        made.start()
        #expect(withServer.bool(forKey: PhoneAccessRules.betaStorageKey))
        made.cancel()

        let withoutServer = Self.scratchDefaults()
        let none = ConnectPhoneModel(
            candidates: [], pollInterval: .milliseconds(20), defaults: withoutServer,
            makeController: { server in RelayController(host: server, registrar: { nil }) })
        none.start()
        #expect(withoutServer.bool(forKey: PhoneAccessRules.betaStorageKey), "the wizard says what is missing, the switch is on")
    }

    @Test func oneServerSkipsThePickerAndGoesStraightToTheQRCode() async {
        let server = WizardServer(name: "Studio")
        server.status = .off
        let wizard = model([server])
        wizard.start()
        #expect(await wait(wizard) { if case .scan(.ready) = $0 { true } else { false } })
        #expect(server.enableCalls == 1 && server.codes == 1)
        if case .scan(.ready(_, _, let hosts, _, let viaCloud)) = wizard.step { #expect(hosts.isEmpty && viaCloud) }
        wizard.cancel()
    }

    @Test func aCloudThatIsAlreadyOnIsTakenAsItIs() async {
        let server = WizardServer(name: "Studio")
        let wizard = model([server])
        wizard.start()
        #expect(await wait(wizard) { if case .scan = $0 { true } else { false } })
        #expect(server.enableCalls == 0)
        wizard.cancel()
    }

    @Test func severalServersAskWhichOneAndOnlyConnectedCapableOnesAreOffered() async {
        let a = WizardServer(name: "A"), b = WizardServer(name: "B"), old = WizardServer(name: "Old"), off = WizardServer(name: "Off")
        old.supportsRelay = false
        off.isConnected = false
        let wizard = model([a, b, old, off])
        wizard.start()
        #expect(wizard.step == .pickServer)
        #expect(wizard.servers.map(\.wizardName) == ["A", "B"])
        wizard.choose(b)
        #expect(await wait(wizard) { if case .scan = $0 { true } else { false } })
        #expect(b.codes == 1 && a.codes == 0)
        wizard.cancel()
    }

    @Test func noUsableServerIsSaidAtOnce() {
        let off = WizardServer(name: "Off")
        off.isConnected = false
        let wizard = model([off])
        wizard.start()
        #expect(wizard.step == .problem(.noServer))
    }

    @Test func withoutAnAccountTheWizardAsksToSignIn() async {
        let server = WizardServer(name: "Studio")
        server.status = .off
        let wizard = model([server], signedIn: false)
        wizard.start()
        #expect(await wait(wizard) { $0 == .problem(.needsSignIn) })
        #expect(server.enableCalls == 0)
    }

    @Test func aPhoneThatAppearsEndsTheWait() async {
        let server = WizardServer(name: "Studio")
        let wizard = model([server])
        wizard.start()
        #expect(await wait(wizard) { if case .scan = $0 { true } else { false } })
        server.devices.append(Device(id: "phone", name: "Anna’s iPhone", createdAt: 2, lastSeenAt: nil, current: nil, platform: "ios"))
        #expect(await wait(wizard) { $0 == .done(device: "Anna’s iPhone") })
    }

    @Test func aCodeThatRunsOutIsReplacedByANewOneWithoutLosingTheBaseline() async {
        let server = WizardServer(name: "Studio")
        server.codeLifetimeMs = 2_100
        let wizard = model([server])
        wizard.start()
        #expect(await wait(wizard) { $0 == .scan(.expired) })
        wizard.newCode()
        #expect(await wait(wizard) { if case .scan(.ready) = $0 { true } else { false } })
        #expect(server.codes == 2)
        // The Mac that was there before is not "the phone".
        try? await Task.sleep(for: .milliseconds(100))
        if case .done = wizard.step { Issue.record("the Mac must not count") }
        wizard.cancel()
    }

    @Test func theBaselineIsTakenOnceEvenWhenTheServerHadNoDevices() async {
        let server = WizardServer(name: "Studio")
        server.devices = []
        server.codeLifetimeMs = 2_100
        let wizard = model([server])
        wizard.start()
        #expect(await wait(wizard) { $0 == .scan(.expired) })
        // A phone shows up while no code is shown; the next code must not take it into the baseline.
        server.devices.append(Device(id: "phone", name: "iPhone", createdAt: 2, lastSeenAt: nil, current: nil, platform: "ios"))
        wizard.newCode()
        #expect(await wait(wizard) { $0 == .done(device: "iPhone") })
    }

    @Test func aServerThatCannotListItsDevicesStopsTheWizardBeforeAnythingIsChanged() async {
        let server = WizardServer(name: "Studio")
        server.status = .off
        server.devicesFail = true
        let wizard = model([server])
        wizard.start()
        #expect(await wait(wizard) { if case .problem = $0 { true } else { false } })
        #expect(server.enableCalls == 0)
    }

    @Test func closingTheWizardStopsTheWatch() async {
        let server = WizardServer(name: "Studio")
        let wizard = model([server])
        wizard.start()
        #expect(await wait(wizard) { if case .scan = $0 { true } else { false } })
        wizard.cancel()
        server.devices.append(Device(id: "phone", name: "iPhone", createdAt: 2, lastSeenAt: nil, current: nil, platform: "ios"))
        try? await Task.sleep(for: .milliseconds(150))
        if case .done = wizard.step { Issue.record("a closed wizard must not go on") }
    }
}

@Suite struct CloudAccessRulesTests {
    @Test func theStatusFollowsThePhaseThenTheProblemThenTheDaemon() {
        typealias R = CloudAccessRules
        let on = RelayStatus(enabled: true, connected: true, sid: "s")
        let waiting = RelayStatus(enabled: true, connected: false, lastError: "bad secret")
        #expect(R.status(phase: .enabling, relay: nil, problem: nil) == .enabling)
        #expect(R.status(phase: .connecting, relay: on, problem: .needsSignIn) == .connecting)
        #expect(R.status(phase: .idle, relay: nil, problem: .needsSignIn) == .signIn)
        #expect(R.status(phase: .idle, relay: nil, problem: .unsupported) == .unsupported)
        #expect(R.status(phase: .idle, relay: nil, problem: .account(AccountError.api(code: "too_many", status: 409))) == .tooMany)
        #expect(R.status(phase: .idle, relay: on, problem: nil) == .connected)
        #expect(R.status(phase: .idle, relay: waiting, problem: nil) == .waiting(reason: "bad secret"))
        #expect(R.status(phase: .idle, relay: .off, problem: nil) == .off)
        #expect(R.status(phase: .idle, relay: nil, problem: nil) == .off)
        if case .failed(let message) = R.status(
            phase: .idle, relay: nil, problem: .daemon(RPCError(code: RPCError.disconnected, message: "x")))
        {
            #expect(!message.text.isEmpty)
        } else {
            Issue.record("a daemon problem is a failure with words")
        }
    }

    @Test func theSwitchShowsWhereTheServerIs() {
        typealias R = CloudAccessRules
        #expect(R.switchIsOn(phase: .enabling, relay: .off, problem: nil))
        #expect(R.switchIsOn(phase: .connecting, relay: .off, problem: nil))
        #expect(!R.switchIsOn(phase: .disabling, relay: RelayStatus(enabled: true, connected: true), problem: nil))
        #expect(R.switchIsOn(phase: .idle, relay: RelayStatus(enabled: true, connected: false), problem: nil))
        #expect(!R.switchIsOn(phase: .idle, relay: .off, problem: .needsSignIn))
    }

    @Test func theTailscaleHelperReplacesTheErrorOnlyForNoTailscale() {
        let none = PhoneAccessStatus(mode: .tailscale, listening: [], error: "No Tailscale address on this machine. Install Tailscale and sign in.")
        #expect(CloudAccessRules.showsTailscaleHelper(mode: .tailscale, status: none))
        #expect(!CloudAccessRules.showsTailscaleHelper(mode: .lan, status: none))
        #expect(!CloudAccessRules.showsTailscaleHelper(mode: .tailscale, status: nil))
        let port = PhoneAccessStatus(mode: .tailscale, listening: [], error: "Address already in use")
        #expect(!CloudAccessRules.showsTailscaleHelper(mode: .tailscale, status: port))
        let up = PhoneAccessStatus(mode: .tailscale, listening: ["100.64.0.1:7879"], error: nil)
        #expect(!CloudAccessRules.showsTailscaleHelper(mode: .tailscale, status: up))
    }

    @Test func theInstallStepFitsTheServersSystem() {
        #expect(CloudAccessRules.install(os: "linux") == .command("curl -fsSL https://tailscale.com/install.sh | sh"))
        #expect(CloudAccessRules.install(os: nil) == .command("curl -fsSL https://tailscale.com/install.sh | sh"))
        if case .app(let url) = CloudAccessRules.install(os: "macos") { #expect(url.host == "tailscale.com") } else { Issue.record("an app on macOS") }
        #expect(CloudAccessRules.loginCommand == "sudo tailscale up")
    }

    @Test func connectingIsPossibleWithTheCloudAloneAndNotWithNothing() {
        #expect(PhoneAccessRules.canConnect(mode: .off, status: nil, cloudConnected: true))
        #expect(!PhoneAccessRules.canConnect(mode: .off, status: nil))
    }
}
