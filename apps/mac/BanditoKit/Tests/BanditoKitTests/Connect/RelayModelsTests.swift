import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

/// The saved shapes, the order of ways in, the pairing through a fake relay, and the controller that turns the cloud on.
@Suite(.serialized) struct RelayModelsTests {
    static let sid = "abcdefghijklmnopqrstuvwxyz"
    static let nk = Base64URL.encode(Data((0..<32).map { UInt8($0 + 1) }))
    static let fp = String(repeating: "ab", count: 32)

    // MARK: saved servers

    @Test func aReachableServerSurvivesSavingAndAnOldDirectOneStaysAsItWas() throws {
        let both = ServerEndpoint.reachable(
            hosts: ["10.0.0.2:7879"], fingerprint: Self.fp, relay: RelayRoute(host: "relay.bandito.dev", sid: Self.sid), noiseKey: Self.nk)
        let only = ServerEndpoint.reachable(
            hosts: [], fingerprint: nil, relay: RelayRoute(host: "relay.bandito.dev", sid: Self.sid), noiseKey: Self.nk)
        for endpoint in [both, only] {
            let config = ServerConfig(name: "Mac", endpoint: endpoint, token: "secret-token", noiseSecret: "secret-key")
            let data = try JSONEncoder().encode([config])
            let text = String(decoding: data, as: UTF8.self)
            // Neither secret is ever written to the saved list.
            #expect(!text.contains("secret-token") && !text.contains("secret-key"))
            let back = try JSONDecoder().decode([ServerConfig].self, from: data)
            #expect(back[0].endpoint == endpoint && back[0].token == nil && back[0].noiseSecret == nil)
        }
        let direct = ServerEndpoint.direct(hosts: ["10.0.0.2:7879"], fingerprint: Self.fp)
        #expect(try JSONDecoder().decode(ServerEndpoint.self, from: JSONEncoder().encode(direct)) == direct)
        #expect(only.directPart == nil && only.relayPart?.route.sid == Self.sid)
        #expect(both.directPart?.hosts == ["10.0.0.2:7879"] && both.pinnedFingerprint == Self.fp)
    }

    @Test func aDamagedReachableRecordIsRefusedNotTrusted() {
        let bad = [
            #"{"reachable":{"hosts":["a:1"],"fingerprint":"zz"}}"#,
            #"{"reachable":{"hosts":[],"relay":{"host":"relay.bandito.dev","sid":"abcdefghijklmnopqrstuvwxyz"}}}"#,
            #"{"reachable":{"hosts":[]}}"#,
            #"{"reachable":{"hosts":["a:1"]}}"#,
            #"{"reachable":{"hosts":[],"relay":{"host":"relay.bandito.dev","sid":"short"},"noiseKey":"AAAA"}}"#,
        ]
        for text in bad {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ServerEndpoint.self, from: Data(text.utf8)) }
        }
    }

    @Test func theSameServerPairedAgainIsRecognisedByItsCertificateOrItsNoiseKey() {
        let route = RelayRoute(host: "relay.bandito.dev", sid: Self.sid)
        let cloudOnly = ServerEndpoint.reachable(hosts: [], fingerprint: nil, relay: route, noiseKey: Self.nk)
        let both = ServerEndpoint.reachable(hosts: ["10.0.0.2:7879"], fingerprint: Self.fp, relay: route, noiseKey: Self.nk)
        let direct = ServerEndpoint.direct(hosts: ["10.0.0.2:7879"], fingerprint: Self.fp)
        #expect(cloudOnly.isSameServer(as: both) && both.isSameServer(as: direct) && direct.isSameServer(as: both))
        #expect(!cloudOnly.isSameServer(as: direct))
        // Every identifier both have must agree: the same certificate behind another Noise key is another server.
        let otherKey = ServerEndpoint.reachable(
            hosts: ["10.0.0.2:7879"], fingerprint: Self.fp, relay: route, noiseKey: Base64URL.encode(Data(repeating: 9, count: 32)))
        #expect(!both.isSameServer(as: otherKey) && both.conflicts(with: otherKey) && otherKey.conflicts(with: both))
        #expect(!both.conflicts(with: direct) && !cloudOnly.conflicts(with: direct) && !both.conflicts(with: cloudOnly))
        #expect(!direct.isSameServer(as: .direct(hosts: ["x:1"], fingerprint: String(repeating: "cd", count: 32))))
    }

    // MARK: order of ways in

    @Test func deadDirectAddressesFallBackToTheRelayAndTheTransportSaysWhich() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        let key = Curve25519.KeyAgreement.PrivateKey()
        relay.learnForTests(key)
        let transport = ReachableTransport(
            hosts: ["127.0.0.1:1"], fingerprint: Self.fp, relay: relay.route, daemonKey: relay.daemonPublicKey, phoneKey: key,
            token: FakeRelay.token, directTimeout: .seconds(1))
        let client = RPCClient(transport: transport)
        try await client.start()
        #expect(await transport.connectedRoute == .cloud)
        await client.close()
    }

    @Test func aServerWithoutAPhoneKeyCannotUseTheRelayAndSaysSo() async {
        let route = RelayRoute(host: "127.0.0.1:9", sid: Self.sid)
        let config = ServerConfig(
            name: "x", endpoint: .reachable(hosts: [], fingerprint: nil, relay: route, noiseKey: Self.nk), token: "t")
        let transport = ReachableTransport(config: config)
        await #expect(throws: RPCError.self) { try await transport.connect() }
    }

    // MARK: pairing

    @Test func pairingKeepsTheDirectShapeWithoutARelayAndNeedsTheKeyWithOne() async {
        let request = PairRequest(
            code: FakeRelay.validCode, fingerprint: nil, name: "x", hosts: [],
            relay: RelayRoute(host: "127.0.0.1:9", sid: Self.sid), noiseKey: "not-a-key")
        await #expect(throws: PairInputError.badRelay) { try await DevicePairing.redeem(request, fingerprint: nil, deviceName: "p") }
        let noWay = PairRequest(code: FakeRelay.validCode, fingerprint: nil, name: "x", hosts: ["h:1"])
        await #expect(throws: PairInputError.badFingerprint) { try await DevicePairing.redeem(noWay, fingerprint: nil, deviceName: "p") }
    }

    @Test func revokingSelfGoesThroughTheRelay() async throws {
        let relay = try FakeRelay()
        defer { relay.stop() }
        let key = Curve25519.KeyAgreement.PrivateKey()
        relay.learnForTests(key)
        let config = ServerConfig(
            name: "x", endpoint: .reachable(hosts: [], fingerprint: nil, relay: relay.route, noiseKey: Base64URL.encode(relay.daemonPublicKey)),
            token: FakeRelay.token, noiseSecret: Base64URL.encode(key.rawRepresentation))
        #expect(await DevicePairing.revokeSelf(config: config))
    }
}

// MARK: - the controller

@MainActor
final class FakeRelayHost: RelayHost {
    var relayName = "Studio"
    var supportsRelay = true
    var status = RelayStatus.off
    var enabled: [(String, String, String)] = []
    var disabledCount = 0
    var enableError: Error?
    /// The daemon takes the registration but the answer is lost: `relayEnable` throws after the status changed.
    var takesThenThrows = false
    /// Statuses the daemon reports after enabling, one per read; the last repeats.
    var afterEnable: [RelayStatus] = [RelayStatus(enabled: true, connected: true, sid: "abcdefghijklmnopqrstuvwxyz", relayUrl: "wss://r")]

    func relayStatus() async throws -> RelayStatus {
        if status.enabled, afterEnable.count > 1, !enabled.isEmpty {
            afterEnable.removeFirst()
            status = afterEnable[0]
        }
        return status
    }
    func relayEnable(url: String, sid: String, secret: String) async throws -> RelayStatus {
        if takesThenThrows {
            status = RelayStatus(enabled: true, connected: true, sid: sid, relayUrl: url)
            throw RPCError(code: RPCError.timedOut, message: "no answer")
        }
        if let enableError { throw enableError }
        enabled.append((url, sid, secret))
        status = afterEnable[0]
        return RelayStatus(enabled: true, connected: false, sid: sid, relayUrl: url)
    }
    func relayDisable() async throws -> RelayStatus {
        disabledCount += 1
        status = .off
        return .off
    }
}

actor FakeRegistrar: RelayRegistrar {
    var registered: [String] = []
    var deleted: [String] = []
    var registerError: Error?
    func setRegisterError(_ error: Error?) { registerError = error }
    func registerRelayServer(name: String) async throws -> RelayRegistration {
        if let registerError { throw registerError }
        registered.append(name)
        return RelayRegistration(sid: "abcdefghijklmnopqrstuvwxyz", secret: "top-secret", relayURL: "wss://relay.bandito.dev")
    }
    func relayServers() async throws -> [RelayServerEntry] { [] }
    func deleteRelayServer(sid: String) async throws { deleted.append(sid) }
}

@MainActor
@Suite struct RelayControllerTests {
    func make(_ host: FakeRelayHost, _ registrar: FakeRegistrar?, timeout: Duration = .seconds(2)) -> RelayController {
        RelayController(host: host, registrar: { registrar }, connectTimeout: timeout, pollInterval: .milliseconds(10))
    }

    @Test func enablingRegistersHandsOverTheSecretAndWaitsForTheConnection() async {
        let host = FakeRelayHost()
        let registrar = FakeRegistrar()
        host.afterEnable = [
            RelayStatus(enabled: true, connected: false, sid: "abcdefghijklmnopqrstuvwxyz"),
            RelayStatus(enabled: true, connected: true, sid: "abcdefghijklmnopqrstuvwxyz"),
        ]
        let controller = make(host, registrar)
        #expect(await controller.enable())
        #expect(host.enabled.count == 1 && host.enabled[0].2 == "top-secret" && host.enabled[0].0 == "wss://relay.bandito.dev")
        #expect(await registrar.registered == ["Studio"])
        #expect(controller.isConnected && controller.problem == nil && controller.phase == .idle)
    }

    @Test func aServerThatIsAlreadyOnIsTakenNotRegisteredAgain() async {
        let host = FakeRelayHost()
        host.status = RelayStatus(enabled: true, connected: true, sid: "abcdefghijklmnopqrstuvwxyz")
        let registrar = FakeRegistrar()
        #expect(await make(host, registrar).enable())
        #expect(await registrar.registered.isEmpty && host.enabled.isEmpty)
    }

    @Test func withoutAnAccountThePersonIsAskedToSignInAndNothingChanges() async {
        let host = FakeRelayHost()
        let controller = make(host, nil)
        #expect(await controller.enable() == false)
        #expect(controller.problem == .needsSignIn && host.enabled.isEmpty)
        let expired = FakeRegistrar()
        await expired.setRegisterError(AccountError.notSignedIn)
        let second = make(host, expired)
        #expect(await second.enable() == false && second.problem == .needsSignIn)
    }

    @Test func aDaemonThatRefusesLeavesNoRegistrationBehind() async {
        let host = FakeRelayHost()
        host.enableError = RPCError(code: -32031, message: "relay_failed")
        let registrar = FakeRegistrar()
        let controller = make(host, registrar)
        #expect(await controller.enable() == false)
        #expect(await registrar.deleted == ["abcdefghijklmnopqrstuvwxyz"])
        if case .daemon? = controller.problem {} else { Issue.record("a daemon problem") }
    }

    @Test func aLostAnswerOfEnableDoesNotDeleteARegistrationTheDaemonTook() async {
        let host = FakeRelayHost()
        host.takesThenThrows = true
        let registrar = FakeRegistrar()
        let controller = make(host, registrar)
        #expect(await controller.enable())
        #expect(await registrar.deleted.isEmpty)
        #expect(controller.isConnected && controller.problem == nil)
    }

    @Test func aCloudThatIsOnButNeverConnectsIsReplacedByANewRegistration() async {
        let host = FakeRelayHost()
        host.status = RelayStatus(enabled: true, connected: false, sid: "oldoldoldoldoldoldoldoldol")
        let registrar = FakeRegistrar()
        let controller = make(host, registrar, timeout: .milliseconds(80))
        #expect(await controller.enable())
        #expect(host.disabledCount == 1)
        #expect(await registrar.deleted == ["oldoldoldoldoldoldoldoldol"])
        #expect(await registrar.registered == ["Studio"] && host.enabled.count == 1)
        #expect(controller.isConnected)
    }

    @Test func aStaleCloudWithoutAnAccountIsLeftAloneAndReported() async {
        let host = FakeRelayHost()
        host.status = RelayStatus(enabled: true, connected: false, sid: "oldoldoldoldoldoldoldoldol")
        let controller = make(host, nil, timeout: .milliseconds(50))
        #expect(await controller.enable() == false)
        #expect(host.disabledCount == 0 && controller.problem == .notConnected(reason: nil))
    }

    @Test func disablingDeletesTheRegistrationTheDaemonHoldsNow() async {
        let host = FakeRelayHost()
        host.status = RelayStatus(enabled: true, connected: true, sid: "abcdefghijklmnopqrstuvwxyz")
        let registrar = FakeRegistrar()
        let controller = make(host, registrar)
        await controller.refresh()
        // The daemon moved to another registration after the last read.
        host.status = RelayStatus(enabled: true, connected: true, sid: "newnewnewnewnewnewnewnewne")
        #expect(await controller.disable())
        #expect(await registrar.deleted == ["newnewnewnewnewnewnewnewne"])
    }

    @Test func tooManyServersIsTheAccountsAnswer() async {
        let host = FakeRelayHost()
        let registrar = FakeRegistrar()
        await registrar.setRegisterError(AccountError.api(code: "too_many", status: 409))
        let controller = make(host, registrar)
        #expect(await controller.enable() == false)
        if case .account(let error)? = controller.problem, case AccountError.api(let code, _) = error {
            #expect(code == "too_many")
        } else {
            Issue.record("an account problem")
        }
        #expect(host.enabled.isEmpty)
    }

    @Test func aServerThatNeverConnectsIsReportedWithItsReason() async {
        let host = FakeRelayHost()
        host.afterEnable = [RelayStatus(enabled: true, connected: false, sid: "abcdefghijklmnopqrstuvwxyz", lastError: "bad secret")]
        let controller = make(host, FakeRegistrar(), timeout: .milliseconds(80))
        #expect(await controller.enable() == false)
        #expect(controller.problem == .notConnected(reason: "bad secret"))
        // It stays on: the daemon keeps trying.
        #expect(controller.isOn)
    }

    @Test func aDaemonWithoutTheFeatureIsToldApart() async {
        let host = FakeRelayHost()
        host.supportsRelay = false
        let controller = make(host, FakeRegistrar())
        #expect(await controller.enable() == false && controller.problem == .unsupported)
    }

    @Test func disablingMakesTheDaemonForgetAndThenDeletesTheRegistration() async {
        let host = FakeRelayHost()
        host.status = RelayStatus(enabled: true, connected: true, sid: "abcdefghijklmnopqrstuvwxyz")
        let registrar = FakeRegistrar()
        let controller = make(host, registrar)
        await controller.refresh()
        #expect(await controller.disable())
        #expect(host.disabledCount == 1 && !controller.isOn)
        #expect(await registrar.deleted == ["abcdefghijklmnopqrstuvwxyz"])
    }

    @Test func disablingWithoutAnAccountStillTurnsTheServerOff() async {
        let host = FakeRelayHost()
        host.status = RelayStatus(enabled: true, connected: true, sid: "abcdefghijklmnopqrstuvwxyz")
        let controller = make(host, nil)
        await controller.refresh()
        #expect(await controller.disable() && host.disabledCount == 1)
    }

    @Test func aSecondTapWhileAStepRunsDoesNothing() async {
        let host = FakeRelayHost()
        host.afterEnable = [RelayStatus(enabled: true, connected: false, sid: "abcdefghijklmnopqrstuvwxyz")]
        let registrar = FakeRegistrar()
        let controller = make(host, registrar, timeout: .milliseconds(300))
        async let first = controller.enable()
        try? await Task.sleep(for: .milliseconds(30))
        let second = await controller.enable()
        _ = await first
        #expect(second == false)
        #expect(await registrar.registered.count == 1)
    }

    @Test func theRegistrationNeverPrintsItsSecret() {
        let registration = RelayRegistration(sid: "s", secret: "top-secret", relayURL: "wss://r")
        #expect(!String(describing: registration).contains("top-secret"))
    }

    @Test func registrationAnswersAreDecodedFromTheWire() throws {
        let created = try JSONDecoder().decode(
            RelayRegistration.self, from: Data(#"{"ok":true,"sid":"abc","secret":"s","relay_url":"wss://relay.bandito.dev"}"#.utf8))
        #expect(created.relayURL == "wss://relay.bandito.dev")
        let list = try JSONDecoder().decode(
            [RelayServerEntry].self,
            from: Data(#"[{"sid":"a","name":"Home","created_at":"x","online":true,"last_seen_at":null}]"#.utf8))
        #expect(list[0].online && list[0].lastSeenAt == nil)
    }
}
