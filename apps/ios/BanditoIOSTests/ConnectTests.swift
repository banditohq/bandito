import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import Bandito

/// A Keychain in memory, so no test touches the real one.
final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failsToSave = false
    var failsToDelete = false
    var failsToLoad = false

    func load(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if failsToLoad { throw SecretStoreError.keychain(-25308) }
        return items[account]
    }

    func save(_ data: Data?, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsToSave, data != nil { throw SecretStoreError.keychain(-25299) }
        if failsToDelete, data == nil { throw SecretStoreError.keychain(-25299) }
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
    var redeemed: [(PairRequest, String?)] = []
    var probed: [DirectHost] = []
    var revoked = 0
    func redeem(_ request: PairRequest, _ pin: String?) { redeemed.append((request, pin)) }
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
        let store: ServerStore
    }

    /// A model over a session with its own defaults and Keychain, a fake redeem that succeeds (or throws `redeemError`),
    /// and a probe that answers `probed`.
    func world(redeemError: Error? = nil, probed: String? = ConnectTests.fp, keychainFails: Bool = false) -> World {
        let defaults = UserDefaults(suiteName: "ios-connect-\(UUID().uuidString)")!
        let secrets = MemorySecrets()
        secrets.failsToSave = keychainFails
        let store = ServerStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json"), defaults: defaults)
        let session = ServerSession(store: store, secrets: secrets, connect: { _ in })
        let calls = PairCalls()
        let model = PairModel(
            session: session, deviceName: "Test iPhone",
            redeem: { request, pin, _ in
                await calls.redeem(request, pin)
                if let redeemError { throw redeemError }
                let endpoint: ServerEndpoint =
                    pin.map { .direct(hosts: request.hosts, fingerprint: $0) }
                    ?? .reachable(hosts: [], fingerprint: nil, relay: request.relay, noiseKey: request.noiseKey)
                let config = ServerConfig(name: request.name, endpoint: endpoint, token: "bdt_token", noiseSecret: request.relay == nil ? nil : "k")
                return PairedDevice(config: config, deviceID: "dev-1", route: request.relay == nil ? .network : .cloud)
            },
            probe: { host in
                await calls.probe(host)
                return probed
            },
            revoke: { _ in await calls.revoke() })
        return World(model: model, session: session, secrets: secrets, defaults: defaults, calls: calls, store: store)
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

    @Test func aScannedLinkIsConfirmedThenPairsAndTheServerIsKept() async {
        let w = world()
        w.model.submitLink(Self.link, origin: .scan)
        guard case .confirmLink(let shown, let origin) = w.model.phase else {
            Issue.record("a scan is confirmed too: \(w.model.phase)")
            return
        }
        #expect(origin == .scan)
        #expect(shown.name == "Studio Mac")
        #expect(shown.hosts == ["10.0.0.2:7879", "100.64.0.1:7879"], "the screen shows where it will connect")
        #expect(await w.calls.redeemed.isEmpty, "nothing is sent before the button")
        w.model.confirmLink()
        await settle(w.model, until: isDone)
        guard case .done(_, let name, _) = w.model.phase else {
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
            guard case .confirmLink(let request, _) = w.model.phase else {
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
        guard case .confirmLink(let request, _) = w.model.phase else {
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
        w.model.confirmLink()
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
        w.model.confirmLink()
        await settle(w.model, until: isFailed)
        #expect(w.model.phase == .failed(.failure(.codeRejected), back: .choose))
        #expect(w.session.servers.isEmpty)
    }

    @Test func aKeyThatCannotBeSavedUndoesThePairing() async {
        let w = world(keychainFails: true)
        w.model.submitLink(Self.link, origin: .scan)
        w.model.confirmLink()
        await settle(w.model, until: isFailed)
        #expect(w.model.phase == .failed(.saveKey, back: .choose))
        #expect(await w.calls.revoked == 1, "the device is taken back off the server")
        #expect(w.session.servers.isEmpty)
        #expect(w.store.load().isEmpty, "no server is listed without its key")
    }

    // MARK: Name

    @Test func theNameCanBeChangedAtTheEnd() async {
        let w = world()
        w.model.submitLink(Self.link, origin: .scan)
        w.model.confirmLink()
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

    // MARK: relay

    static let sid = "abcdefghijklmnopqrstuvwxyz"
    static let nk = Base64URL.encode(Data(repeating: 5, count: 32))
    static let cloudLink = "bandito://pair?v=1&code=\(code)&name=Studio&relay=relay.bandito.dev/\(sid)&nk=\(nk)"

    @Test func aRelayOnlyLinkIsConfirmedAndConnectsWithoutAPin() async {
        let w = world()
        w.model.submitLink(Self.cloudLink, origin: .scan)
        guard case .confirmLink(let request, _) = w.model.phase else {
            Issue.record("not shown first: \(w.model.phase)")
            return
        }
        #expect(request.isRelayOnly)
        #expect(await w.calls.redeemed.isEmpty, "nothing is sent before the button")
        w.model.confirmLink()
        await settle(w.model, until: isDone)
        let calls = await w.calls.redeemed
        #expect(calls.count == 1 && calls.first?.1 == nil && calls.first?.0.relay?.sid == Self.sid)
    }

    @Test func theCloudsFailuresHaveTheirOwnWords() {
        let offline = RPCError(code: RPCError.relay, message: "relay_offline: x")
        #expect(PairFailure.classify(offline) == .serverOffline)
        #expect(PairFailure.classify(RPCError(code: RPCError.relay, message: "relay_limit: x")) == .cloudLimit)
        #expect(PairFailure.classify(RPCError(code: RPCError.relay, message: "relay_key_mismatch: x")) == .cloudKey)
        #expect(PairFailure.classify(RPCError(code: RPCError.rateLimited, message: "relay_busy: x")) == .tooManyAttempts)
        #expect(PairProblemText(.failure(.serverOffline)).message == L10n.Ios.Connect.Error.offline)
        #expect(PairProblemText(.failure(.cloudKey)).isAlarm)
    }

    @Test func aServerOnTheCloudSaysSoInTheList() {
        let config = ServerConfig(
            name: "Studio",
            endpoint: .reachable(hosts: [], fingerprint: nil, relay: RelayRoute(host: "relay.bandito.dev", sid: Self.sid), noiseKey: Self.nk),
            token: "t")
        let facts = ServerRowFacts.make(ServerModel(config: config))
        #expect(facts.via == .cloud && facts.addresses.isEmpty)
        #expect(facts.viaTitle == L10n.Ios.Settings.Servers.Via.cloud)
    }

}

/// The saved servers: what is stored where, and what a launch brings back.
@MainActor
@Suite struct ServerSessionTests {
    func make(secrets: MemorySecrets = MemorySecrets(), store: ServerStore? = nil) -> (ServerSession, MemorySecrets, ServerStore) {
        let store = store ?? ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json"),
            defaults: UserDefaults(suiteName: "ios-session-\(UUID().uuidString)")!)
        return (ServerSession(store: store, secrets: secrets, connect: { _ in }), secrets, store)
    }

    func config(_ name: String = "Mac", fingerprint: String = ConnectTests.fp, token: String? = "tok") -> ServerConfig {
        ServerConfig(name: name, endpoint: .direct(hosts: ["10.0.0.2:7879"], fingerprint: fingerprint), token: token)
    }

    @Test func aServerIsSavedWithoutItsTokenAndComesBackWithIt() throws {
        let (session, secrets, store) = make()
        let added = config()
        try session.add(added)
        let saved = try Data(contentsOf: store.fileURL)
        #expect(!String(decoding: saved, as: UTF8.self).contains("tok"))
        #expect(store.isExcludedFromBackup, "the addresses stay out of backups")
        #expect(secrets.count == 1)
        let (again, _, _) = make(secrets: secrets, store: store)
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
        let (session, secrets, store) = make()
        try session.add(config())
        try secrets.save(nil, account: try #require(session.active?.id.uuidString))
        let (again, _, _) = make(secrets: secrets, store: store)
        again.loadIfNeeded(arguments: [])
        #expect(again.servers.isEmpty)
    }

    @Test func removingForgetsTheKeyToo() throws {
        let (session, secrets, store) = make()
        try session.add(config())
        session.remove(try #require(session.active?.id))
        #expect(session.servers.isEmpty)
        #expect(secrets.count == 0 || (try? secrets.load(account: "x")) == nil)
        let (again, _, _) = make(secrets: secrets, store: store)
        again.loadIfNeeded(arguments: [])
        #expect(again.servers.isEmpty)
    }

    @Test func theResetArgumentStartsFromNothing() throws {
        let (session, secrets, store) = make()
        try session.add(config())
        let (again, _, _) = make(secrets: secrets, store: store)
        again.loadIfNeeded(arguments: ["Bandito", ServerSession.resetArgument])
        #expect(again.servers.isEmpty)
        #expect(store.load().isEmpty)
    }

    @Test func aDamagedListIsNotTrusted() throws {
        let (_, _, store) = make()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        let (session, _, _) = make(store: store)
        session.loadIfNeeded(arguments: [])
        #expect(session.servers.isEmpty)
    }

    @Test func aListKeptInUserDefaultsByAnEarlierVersionMovesToTheFile() throws {
        let defaults = UserDefaults(suiteName: "ios-legacy-\(UUID().uuidString)")!
        let file = FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json")
        let legacy = config("Old")
        defaults.set(try JSONEncoder().encode([legacy]), forKey: ServerStore.legacyKey)
        let store = ServerStore(fileURL: file, defaults: defaults)
        #expect(store.load().first?.name == "Old")
        #expect(defaults.data(forKey: ServerStore.legacyKey) == nil, "the old copy is gone")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(store.isExcludedFromBackup)
        #expect(store.load().first?.name == "Old", "and it reads from the file now")
    }

    @Test func renamingCleansTheName() throws {
        let (session, _, store) = make()
        try session.add(config("Mac"))
        let id = try #require(session.active?.id)
        session.rename(id, to: "Work\u{202E}gpj\u{200B} Mac")
        #expect(session.active?.config.name == "Workgpj Mac")
        session.rename(id, to: "\u{202E}\u{200B}")
        #expect(session.active?.config.name == "Workgpj Mac", "nothing left changes nothing")
        session.rename(id, to: String(repeating: "x", count: 100))
        #expect(session.active?.config.name.unicodeScalars.count == 64)
        #expect(store.load().first?.name.unicodeScalars.count == 64, "and it is saved")
    }

    @Test func disconnectingAsksTheServerThenForgetsEverything() async throws {
        let (session, secrets, store) = make()
        session.revokeSelf = { config in
            // The token reaches the call, the way the app would authenticate.
            return config.token == "tok"
        }
        try session.add(config("Mac"))
        let id = try #require(session.active?.id)
        DirectHostMemory.shared.remember("10.0.0.2:7879", for: ConnectTests.fp)
        let result = await session.disconnect(id)
        #expect(result == .removed(revokedOnServer: true))
        #expect(session.servers.isEmpty)
        #expect(secrets.count == 0 || (try? secrets.load(account: id.uuidString)) == nil)
        #expect(store.load().isEmpty)
        #expect(DirectHostMemory.shared.lastGood(for: ConnectTests.fp) == nil, "the remembered address is forgotten")
        #expect(await session.disconnect(UUID()) == .unknown)
    }

    @Test func aServerThatIsOffIsStillForgottenHere() async throws {
        let (session, _, _) = make()
        session.revokeSelf = { _ in false }
        try session.add(config("Mac"))
        let result = await session.disconnect(try #require(session.active?.id))
        #expect(result == .removed(revokedOnServer: false))
        #expect(session.servers.isEmpty)
    }

    @Test func aKeychainThatRefusesKeepsTheServerWhenDisconnecting() async throws {
        let (session, secrets, _) = make()
        session.revokeSelf = { _ in true }
        try session.add(config("Mac"))
        secrets.failsToDelete = true
        let result = await session.disconnect(try #require(session.active?.id))
        #expect(result == .keychainRefused)
        #expect(session.servers.count == 1)
    }

    @Test func theDemoWorldIsWhatTheScreensShowAndNothingIsSaved() async {
        let (session, _, store) = make()
        #expect(session.current.isEmpty)
        let demo = ServerModel(config: ServerConfig(name: "Demo", endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:9/demo")!)))
        session.installDemo([demo])
        #expect(session.current.map(\.id) == [demo.id])
        #expect(session.servers.isEmpty)
        #expect(store.load().isEmpty)
    }

    @Test func theSettingsRowShowsHowTheServerIsReached() throws {
        let memory = DirectHostMemory(defaults: UserDefaults(suiteName: "ios-row-\(UUID().uuidString)")!)
        let endpoint = ServerEndpoint.direct(hosts: ["192.168.1.5:7879", "100.64.0.1:7879"], fingerprint: ConnectTests.fp)
        let server = ServerModel(config: ServerConfig(name: "Mac", endpoint: endpoint))
        #expect(ServerRowFacts.make(server, memory: memory).via == .lan, "the first address, with none remembered")
        memory.remember("100.64.0.1:7879", for: ConnectTests.fp)
        let facts = ServerRowFacts.make(server, memory: memory)
        #expect(facts.via == .tailscale)
        #expect(facts.addresses == ["192.168.1.5:7879", "100.64.0.1:7879"])
        #expect(!facts.isOnline, "not connected yet")
        #expect(facts.name == "Mac")
    }

    @Test func theBackgroundCheckReadsOnlyTheServersOfTheSession() async throws {
        let (session, _, _) = make()
        let source = SessionNotificationSource(session: session)
        #expect(source.servers.isEmpty)
        let events = try await source.events(after: 0, serverID: UUID())
        #expect(events.isEmpty, "an unknown server has no events")
    }
}

/// The saved list on disk: a damaged record, a file that is not a list, a file that is locked, and the names in it.
@MainActor
@Suite struct ServerStoreTests {
    private func store() -> ServerStore {
        ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json"),
            defaults: UserDefaults(suiteName: "ios-store-\(UUID().uuidString)")!)
    }

    private func config(_ name: String, _ host: String = "10.0.0.2:7879") -> ServerConfig {
        ServerConfig(name: name, endpoint: .direct(hosts: [host], fingerprint: ConnectTests.fp), token: "tok")
    }

    private func write(_ text: String, to store: ServerStore) throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
    }

    @Test func aDamagedRecordIsSkippedAndTheOthersLoad() throws {
        let store = store()
        let good = try String(decoding: JSONEncoder().encode(config("Good")), as: UTF8.self)
        try write("[\(good), {\"id\": 5, \"endpoint\": \"nonsense\"}, \(good.replacingOccurrences(of: "Good", with: "Second"))]", to: store)
        guard case .configs(let configs, let skipped) = store.read() else {
            Issue.record("the list did not read")
            return
        }
        #expect(configs.map(\.name) == ["Good", "Second"])
        #expect(skipped == 1)
    }

    @Test func savingAfterADamagedRecordKeepsTheOldFileAside() throws {
        let store = store()
        let good = try String(decoding: JSONEncoder().encode(config("Good")), as: UTF8.self)
        let original = "[\(good), {\"broken\": true}]"
        try write(original, to: store)
        #expect(store.save([config("New")]))
        #expect(store.load().map(\.name) == ["New"])
        let aside = try #require(store.asideFiles.first)
        #expect(try String(contentsOf: aside, encoding: .utf8) == original, "nothing the person had is lost")
    }

    @Test func aFileThatIsNotAListIsMovedAsideNotWrittenOver() throws {
        let store = store()
        try write("this is not json at all", to: store)
        #expect(store.read() == .unreadable)
        #expect(store.load().isEmpty)
        #expect(store.save([config("New")]))
        #expect(store.load().map(\.name) == ["New"])
        #expect(try String(contentsOf: try #require(store.asideFiles.first), encoding: .utf8) == "this is not json at all")
    }

    @Test func aGoodFileLeavesNothingAside() throws {
        let store = store()
        #expect(store.save([config("A")]))
        #expect(store.save([config("A"), config("B")]))
        #expect(store.asideFiles.isEmpty)
        #expect(store.load().count == 2)
    }

    @Test func aFileThatCannotBeReadNowIsNotTouched() throws {
        let store = store()
        #expect(store.save([config("Keep")]))
        // Locked, as a protected file is before the first unlock after a restart.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path) }
        #expect(store.read() == .unavailable)
        #expect(!store.save([config("Other")]), "nothing is written over a file that could not be read")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(store.load().map(\.name) == ["Keep"])
        #expect(store.asideFiles.isEmpty)
    }

    @Test func namesFromOldRecordsAreCleaned() throws {
        let store = store()
        #expect(store.save([config("Mac\u{202E}gpj\u{200B}"), config("\u{202E}", "192.168.1.9:7879")]))
        let names = store.load().map(\.name)
        #expect(names == ["Macgpj", "192.168.1.9:7879"], "an empty name falls back to the address")
    }
}

@MainActor
@Suite struct ServerSessionSafetyTests {
    private func session(secrets: MemorySecrets = MemorySecrets(), store: ServerStore? = nil) -> (ServerSession, MemorySecrets, ServerStore) {
        let store = store ?? ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json"),
            defaults: UserDefaults(suiteName: "ios-safety-\(UUID().uuidString)")!)
        let session = ServerSession(store: store, secrets: secrets, connect: { _ in })
        session.forgetCursor = { _ in }
        return (session, secrets, store)
    }

    private func config(_ name: String = "Mac", fingerprint: String = ConnectTests.fp) -> ServerConfig {
        ServerConfig(name: name, endpoint: .direct(hosts: ["10.0.0.2:7879"], fingerprint: fingerprint), token: "tok")
    }

    @Test func aListThatCannotBeReadYetIsReadAgainAndNeverWrittenMeanwhile() throws {
        let (first, secrets, store) = session()
        try first.add(config("Keep"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        let (later, _, _) = session(secrets: secrets, store: store)
        later.loadIfNeeded(arguments: [])
        #expect(!later.loaded, "not loaded: the read stays open")
        #expect(later.servers.isEmpty)
        // A pairing in this state does not write the half-known list over the saved one.
        try? later.add(config("Another", fingerprint: String(repeating: "cd", count: 32)))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(store.load().map(\.name) == ["Keep"], "the saved servers are intact")
        // Unlocked: the next call reads them.
        later.loadIfNeeded(arguments: [])
        #expect(later.loaded)
        #expect(Set(later.servers.map(\.config.name)).contains("Keep"))
    }

    @Test func aTokenThatCannotBeReadYetKeepsTheReadOpen() throws {
        let (first, secrets, store) = session()
        try first.add(config("Keep"))
        secrets.failsToLoad = true
        let (later, _, _) = session(secrets: secrets, store: store)
        later.loadIfNeeded(arguments: [])
        #expect(!later.loaded)
        secrets.failsToLoad = false
        later.loadIfNeeded(arguments: [])
        #expect(later.loaded)
        #expect(later.servers.count == 1)
    }

    @Test func disconnectingRemovesTheTokenBeforeAskingTheServerAndForgetsTheCursor() async throws {
        let (session, secrets, store) = session()
        var forgotten: [UUID] = []
        session.forgetCursor = { forgotten.append($0) }
        try session.add(config())
        let id = try #require(session.servers.first?.id)
        final class Seen: @unchecked Sendable {
            var token: String?
            var keychainEmpty = false
        }
        let seen = Seen()
        session.revokeSelf = { config in
            seen.token = config.token
            seen.keychainEmpty = ((try? secrets.load(account: id.uuidString)) ?? nil) == nil
            return true
        }
        #expect(await session.disconnect(id) == .removed(revokedOnServer: true))
        #expect(seen.token == "tok", "the call to the server still carries the token")
        #expect(seen.keychainEmpty, "the Keychain no longer holds it")
        #expect(forgotten == [id])
        #expect(store.load().isEmpty)
    }

    @Test func aSecondDisconnectWhileOneRunsDoesNothing() async throws {
        let (session, _, _) = session()
        try session.add(config())
        let id = try #require(session.servers.first?.id)
        let gate = AsyncGate()
        session.revokeSelf = { _ in
            await gate.wait()
            return true
        }
        let first = Task { await session.disconnect(id) }
        for _ in 0..<200 where !session.disconnecting.contains(id) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(session.disconnecting.contains(id))
        #expect(await session.disconnect(id) == .busy)
        await gate.open()
        #expect(await first.value == .removed(revokedOnServer: true))
        #expect(!session.disconnecting.contains(id))
        #expect(session.servers.isEmpty)
    }

    @Test func aNewServersCursorStartsAtItsTail() async throws {
        let defaults = UserDefaults(suiteName: "ios-cursor-\(UUID().uuidString)")!
        let cursor = NotificationCursor(defaults: defaults)
        let demo = await IOSDemo.start()
        defer { Task { await demo.disconnect() } }
        #expect(demo.currentSeq > 0)
        #expect(cursor.seq(for: demo.id) == 0)
        cursor.baseline(for: demo)
        #expect(cursor.seq(for: demo.id) == demo.currentSeq, "the first check shows nothing of what came before")
        // A server that already has a cursor keeps it.
        cursor.baseline(for: demo)
        #expect(cursor.seq(for: demo.id) == demo.currentSeq)
        cursor.forget(serverID: demo.id)
        #expect(cursor.seq(for: demo.id) == 0)
    }
}

/// Holds a call until `open`, for the tests of two calls at once.
actor AsyncGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiting { waiter.resume() }
        waiting = []
    }
}
