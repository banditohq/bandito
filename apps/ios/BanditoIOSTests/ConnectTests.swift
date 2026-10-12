import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// A Keychain in memory, so no test touches the real one.
final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failsToSave = false

    func load(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]
    }

    func save(_ data: Data?, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsToSave, data != nil { throw SecretStoreError.keychain(-25299) }
        items[account] = data
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}

/// Counts what the fake pairing did.
actor PairCalls {
    var redeemed: [(PairRequest, String)] = []
    var probed: [DirectHost] = []
    var revoked = 0
    func redeem(_ request: PairRequest, _ pin: String) { redeemed.append((request, pin)) }
    func probe(_ host: DirectHost) { probed.append(host) }
    func revoke() { revoked += 1 }
}

@MainActor
@Suite struct ConnectTests {
    static let fp = String(repeating: "ab", count: 32)
    static let code = "otter-lava-mint-orbit-crane-fig"
    static let link = PhonePairLink.make(code: code, fingerprint: fp, name: "Studio Mac", hosts: ["10.0.0.2:7879", "100.64.0.1:7879"])

    struct World {
        let model: PairModel
        let session: ServerSession
        let secrets: MemorySecrets
        let defaults: UserDefaults
        let calls: PairCalls
    }

    /// A model over a session with its own defaults and Keychain, a fake redeem that succeeds (or throws `redeemError`),
    /// and a probe that answers `probed`.
    func world(redeemError: Error? = nil, probed: String? = ConnectTests.fp, keychainFails: Bool = false) -> World {
        let defaults = UserDefaults(suiteName: "ios-connect-\(UUID().uuidString)")!
        let secrets = MemorySecrets()
        secrets.failsToSave = keychainFails
        let session = ServerSession(defaults: defaults, secrets: secrets, connect: { _ in })
        let calls = PairCalls()
        let model = PairModel(
            session: session, deviceName: "Test iPhone",
            redeem: { request, pin, _ in
                await calls.redeem(request, pin)
                if let redeemError { throw redeemError }
                let config = ServerConfig(
                    name: request.name, endpoint: .direct(hosts: request.hosts, fingerprint: pin), token: "bdt_token")
                return PairedDevice(config: config, deviceID: "dev-1")
            },
            probe: { host in
                await calls.probe(host)
                return probed
            },
            revoke: { _ in await calls.revoke() })
        return World(model: model, session: session, secrets: secrets, defaults: defaults, calls: calls)
    }

    func settle(_ model: PairModel, until done: (PairModel.Phase) -> Bool) async {
        for _ in 0..<400 {
            if done(model.phase) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func isDone(_ phase: PairModel.Phase) -> Bool {
        if case .done = phase { return true }
        return false
    }

    func isFailed(_ phase: PairModel.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    // MARK: Scanning and links

    @Test func aScannedLinkPairsAtOnceAndTheServerIsKept() async {
        let w = world()
        w.model.submitLink(Self.link, origin: .scan)
        await settle(w.model, until: isDone)
        guard case .done(_, let name) = w.model.phase else {
            Issue.record("not done: \(w.model.phase)")
            return
        }
        #expect(name == "Studio Mac")
        #expect(w.session.servers.count == 1)
        #expect(w.session.active?.config.token == "bdt_token")
        let calls = await w.calls.redeemed
        #expect(calls.count == 1)
        #expect(calls.first?.1 == Self.fp, "the pin is the link's fingerprint")
        #expect(calls.first?.0.hosts == ["10.0.0.2:7879", "100.64.0.1:7879"])
    }

    @Test func aPastedOrOpenedLinkWaitsForTheButton() async {
        for origin in [LinkOrigin.paste, .url] {
            let w = world()
            w.model.submitLink("Look: \(Self.link)", origin: origin)
            guard case .confirmLink(let request) = w.model.phase else {
            Issue.record("no confirmation: \(w.model.phase)")
            return
        }
            #expect(request.name == "Studio Mac")
            #expect(await w.calls.redeemed.isEmpty, "nothing is sent before the person agrees")
            w.model.confirmLink()
            await settle(w.model, until: isDone)
            #expect(isDone(w.model.phase))
            #expect(await w.calls.redeemed.count == 1)
        }
    }

    @Test func cancellingAConfirmationSendsNothing() async {
        let w = world()
        w.model.submitLink(Self.link, origin: .url)
        w.model.backToChoose()
        #expect(w.model.phase == .choose)
        #expect(await w.calls.redeemed.isEmpty)
        #expect(w.session.servers.isEmpty)
    }

    @Test func garbageIsNamedAndNothingIsSent() async {
        let w = world()
        w.model.submitLink("https://example.com", origin: .scan)
        #expect(w.model.phase == .failed(.input(.notALink), back: .choose))
        w.model.tryAgain()
        #expect(w.model.phase == .choose)
        w.model.submitLink(Self.link.replacingOccurrences(of: "v=1", with: "v=9"), origin: .paste)
        #expect(w.model.phase == .failed(.input(.updateApp), back: .choose))
        #expect(await w.calls.redeemed.isEmpty)
    }

    @Test func aSecondLinkWhileWorkingOrWaitingIsIgnored() async {
        let w = world()
        w.model.submitLink(Self.link, origin: .paste)
        w.model.submitLink(Self.link.replacingOccurrences(of: "Studio%20Mac", with: "Other"), origin: .scan)
        guard case .confirmLink(let request) = w.model.phase else {
            Issue.record("\(w.model.phase)")
            return
        }
        #expect(request.name == "Studio Mac", "the one waiting for an answer is not replaced")
    }

    // MARK: Typed

    @Test func anAddressWithAFingerprintConnectsWithThatPin() async {
        let w = world()
        w.model.showManual()
        w.model.submitManual(address: "mac.local", code: "Otter Lava mint orbit crane fig", fingerprint: Self.fp.uppercased())
        await settle(w.model, until: isDone)
        let calls = await w.calls.redeemed
        #expect(calls.first?.1 == Self.fp)
        #expect(calls.first?.0.hosts == ["mac.local:7879"])
        #expect(await w.calls.probed.isEmpty, "no need to ask the server for what the person typed")
    }

    @Test func anAddressWithoutAFingerprintShowsWhatTheServerPresentsAndWaits() async {
        let w = world(probed: String(repeating: "cd", count: 32))
        w.model.showManual()
        w.model.submitManual(address: "10.0.0.2", code: Self.code, fingerprint: "")
        await settle(w.model) { if case .trust = $0 { return true } else { return false } }
        guard case .trust(let request, let seen) = w.model.phase else {
            Issue.record("\(w.model.phase)")
            return
        }
        #expect(seen == String(repeating: "cd", count: 32))
        #expect(request.hosts == ["10.0.0.2:7879"])
        #expect(await w.calls.redeemed.isEmpty, "the code stays on the phone until the person compares")
        #expect(await w.calls.probed == [DirectHost(host: "10.0.0.2", port: 7879)])
        w.model.confirmTrust()
        await settle(w.model, until: isDone)
        #expect(await w.calls.redeemed.first?.1 == String(repeating: "cd", count: 32))
    }

    @Test func aServerThatDoesNotAnswerTheProbeIsUnreachable() async {
        let w = world(probed: nil)
        w.model.showManual()
        w.model.submitManual(address: "10.0.0.2", code: Self.code, fingerprint: "")
        await settle(w.model, until: isFailed)
        #expect(w.model.phase == .failed(.failure(.unreachable), back: .manual))
        w.model.tryAgain()
        #expect(w.model.phase == .manual, "typing again starts from the typed form")
    }

    @Test func badTypingIsNamedAndTheFormComesBack() {
        let w = world()
        w.model.showManual()
        w.model.submitManual(address: "http://x", code: Self.code, fingerprint: "")
        #expect(w.model.phase == .failed(.input(.badAddress), back: .manual))
        w.model.tryAgain()
        w.model.submitManual(address: "mac.local", code: "one two", fingerprint: "")
        #expect(w.model.phase == .failed(.input(.badCode), back: .manual))
        w.model.tryAgain()
        w.model.submitManual(address: "mac.local", code: Self.code, fingerprint: "xyz")
        #expect(w.model.phase == .failed(.input(.badFingerprint), back: .manual))
    }

    // MARK: Failures

    @Test func aCertificateThatDoesNotMatchIsTheLoudFailureAndSavesNothing() async {
        let w = world(redeemError: RPCError.fingerprintMismatch)
        w.model.submitLink(Self.link, origin: .scan)
        await settle(w.model, until: isFailed)
        #expect(w.model.phase == .failed(.failure(.fingerprintMismatch), back: .choose))
        #expect(PairProblemText(.failure(.fingerprintMismatch)).isAlarm)
        #expect(PairProblemText(.failure(.fingerprintMismatch)).title != nil)
        #expect(!PairProblemText(.failure(.unreachable)).isAlarm)
        #expect(w.session.servers.isEmpty)
        #expect(w.secrets.count == 0)
    }

    @Test func eachFailureHasItsOwnWords() {
        let all: [PairProblem] = [
            .failure(.codeRejected), .failure(.tooManyAttempts), .failure(.fingerprintMismatch), .failure(.unreachable),
            .failure(.other), .saveKey, .input(.notALink), .input(.updateApp), .input(.badCode), .input(.badFingerprint),
            .input(.noAddress), .input(.badAddress),
        ]
        let messages = all.map { PairProblemText($0).message }
        #expect(Set(messages).count == all.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    @Test func aRefusedCodeIsSaidAndNothingIsKept() async {
        let w = world(redeemError: RPCError(code: RPCError.unauthorized, message: "invalid or expired code"))
        w.model.submitLink(Self.link, origin: .scan)
        await settle(w.model, until: isFailed)
        #expect(w.model.phase == .failed(.failure(.codeRejected), back: .choose))
        #expect(w.session.servers.isEmpty)
    }

    @Test func aKeyThatCannotBeSavedUndoesThePairing() async {
        let w = world(keychainFails: true)
        w.model.submitLink(Self.link, origin: .scan)
        await settle(w.model, until: isFailed)
        #expect(w.model.phase == .failed(.saveKey, back: .choose))
        #expect(await w.calls.revoked == 1, "the device is taken back off the server")
        #expect(w.session.servers.isEmpty)
        #expect(w.defaults.data(forKey: ServerSession.configsKey) == nil, "no server is listed without its key")
    }

    // MARK: Name

    @Test func theNameCanBeChangedAtTheEnd() async {
        let w = world()
        w.model.submitLink(Self.link, origin: .scan)
        await settle(w.model, until: isDone)
        w.model.finish(name: "  Work Mac  ")
        #expect(w.session.active?.config.name == "Work Mac")
        w.model.finish(name: "   ")
        #expect(w.session.active?.config.name == "Work Mac", "an empty name changes nothing")
    }

    // MARK: Camera and fingerprint text

    @Test func theCameraStatesFollowThePermission() {
        #expect(CameraAccess.from(status: .notDetermined, hasCamera: true) == .notAsked)
        #expect(CameraAccess.from(status: .authorized, hasCamera: true) == .allowed)
        #expect(CameraAccess.from(status: .denied, hasCamera: true) == .denied)
        #expect(CameraAccess.from(status: .restricted, hasCamera: true) == .denied)
        #expect(CameraAccess.from(status: .authorized, hasCamera: false) == .unavailable)
        #expect(CameraAccess.from(status: .notDetermined, hasCamera: false) == .unavailable)
    }

    @Test func theFingerprintIsShownInFourLinesOfEightPairs() {
        let lines = FingerprintLines.lines(String(repeating: "ab", count: 32))
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0 == "AB:AB:AB:AB:AB:AB:AB:AB" })
        #expect(FingerprintLines.lines("").isEmpty)
    }
}

/// The saved servers: what is stored where, and what a launch brings back.
@MainActor
@Suite struct ServerSessionTests {
    func make(secrets: MemorySecrets = MemorySecrets(), defaults: UserDefaults? = nil) -> (ServerSession, MemorySecrets, UserDefaults) {
        let defaults = defaults ?? UserDefaults(suiteName: "ios-session-\(UUID().uuidString)")!
        return (ServerSession(defaults: defaults, secrets: secrets, connect: { _ in }), secrets, defaults)
    }

    func config(_ name: String = "Mac", fingerprint: String = ConnectTests.fp, token: String? = "tok") -> ServerConfig {
        ServerConfig(name: name, endpoint: .direct(hosts: ["10.0.0.2:7879"], fingerprint: fingerprint), token: token)
    }

    @Test func aServerIsSavedWithoutItsTokenAndComesBackWithIt() throws {
        let (session, secrets, defaults) = make()
        let added = config()
        try session.add(added)
        let saved = try #require(defaults.data(forKey: ServerSession.configsKey))
        #expect(!String(decoding: saved, as: UTF8.self).contains("tok"))
        #expect(secrets.count == 1)
        let (again, _, _) = make(secrets: secrets, defaults: defaults)
        again.loadIfNeeded(arguments: [])
        #expect(again.servers.count == 1)
        #expect(again.active?.config.token == "tok")
        #expect(again.active?.config.endpoint == added.endpoint)
    }

    @Test func pairingTheSameServerAgainReplacesItAndKeepsItsPlace() throws {
        let (session, secrets, _) = make()
        try session.add(config("First", token: "one"))
        let id = try #require(session.active?.id)
        try session.add(config("Second", token: "two"))
        #expect(session.servers.count == 1)
        #expect(session.active?.id == id, "the same record, so its selection and Keychain item stay")
        #expect(session.active?.config.token == "two")
        #expect(secrets.count == 1)
        try session.add(config("Other", fingerprint: String(repeating: "cd", count: 32)))
        #expect(session.servers.count == 2)
    }

    @Test func aKeychainThatRefusesLeavesTheOldServerAsItWas() throws {
        let (session, secrets, _) = make()
        try session.add(config("First", token: "one"))
        secrets.failsToSave = true
        #expect(throws: ServerSession.SessionError.keychain) { try session.add(config("Second", token: "two")) }
        #expect(session.active?.config.name == "First")
        #expect(session.active?.config.token == "one")
    }

    @Test func aServerWithoutATokenIsNotAdded() {
        let (session, _, _) = make()
        #expect(throws: ServerSession.SessionError.noToken) { try session.add(config(token: nil)) }
        #expect(throws: ServerSession.SessionError.noToken) { try session.add(config(token: "")) }
        #expect(session.servers.isEmpty)
    }

    @Test func aSavedServerWhoseTokenIsGoneIsNotConnected() throws {
        let (session, secrets, defaults) = make()
        try session.add(config())
        try secrets.save(nil, account: try #require(session.active?.id.uuidString))
        let (again, _, _) = make(secrets: secrets, defaults: defaults)
        again.loadIfNeeded(arguments: [])
        #expect(again.servers.isEmpty)
    }

    @Test func removingForgetsTheKeyToo() throws {
        let (session, secrets, defaults) = make()
        try session.add(config())
        session.remove(try #require(session.active?.id))
        #expect(session.servers.isEmpty)
        #expect(secrets.count == 0 || (try? secrets.load(account: "x")) == nil)
        let (again, _, _) = make(secrets: secrets, defaults: defaults)
        again.loadIfNeeded(arguments: [])
        #expect(again.servers.isEmpty)
    }

    @Test func theResetArgumentStartsFromNothing() throws {
        let (session, secrets, defaults) = make()
        try session.add(config())
        let (again, _, _) = make(secrets: secrets, defaults: defaults)
        again.loadIfNeeded(arguments: ["Bandito", ServerSession.resetArgument])
        #expect(again.servers.isEmpty)
        #expect(defaults.data(forKey: ServerSession.configsKey) == nil)
    }

    @Test func aDamagedListIsNotTrusted() {
        let defaults = UserDefaults(suiteName: "ios-damaged-\(UUID().uuidString)")!
        defaults.set(Data("not json".utf8), forKey: ServerSession.configsKey)
        let (session, _, _) = make(defaults: defaults)
        session.loadIfNeeded(arguments: [])
        #expect(session.servers.isEmpty)
    }
}
