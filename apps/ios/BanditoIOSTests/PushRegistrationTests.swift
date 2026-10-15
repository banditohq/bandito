import BanditoKit
import Foundation
import Testing

@testable import Bandito

// MARK: fakes

@MainActor
final class FakePushServer: PushServerAPI {
    struct Registration: Equatable {
        var handle: String
        var key: Data
        var serverRef: String
        var kinds: [String]
        var lang: String?
    }

    let pushRef: String
    var isConnected = true
    var supportsPush = true
    var registrations: [Registration] = []
    var unregisters = 0
    var statusCalls = 0
    var registeredOnDaemon = true
    var failRegister = false

    init(_ ref: String = UUID().uuidString) {
        pushRef = ref
    }

    func pushRegister(handle: String, key: Data, serverRef: String, kinds: [String], lang: String?) async throws {
        if failRegister { throw RPCError(code: -32603, message: "no") }
        registrations.append(Registration(handle: handle, key: key, serverRef: serverRef, kinds: kinds, lang: lang))
    }

    func pushUnregister() async throws {
        unregisters += 1
    }

    func pushIsRegistered() async throws -> Bool {
        statusCalls += 1
        return registeredOnDaemon
    }
}

@MainActor
final class FakeHandleSource: PushHandleSource {
    var handle: String?
    /// What `ensureHandle` makes the handle when it is asked (nil: the cloud cannot be reached).
    var onEnsure: String?
    var ensured: [Bool] = []

    init(handle: String?) {
        self.handle = handle
    }

    func ensureHandle(force: Bool) async {
        ensured.append(force)
        if let onEnsure { handle = onEnsure }
    }
}

/// A registrar on fakes, as the coordinator builds the real one.
@MainActor
final class RegistrarHarness {
    let keychain = PushKeychain(secrets: MemoryPushSecrets())
    let device: FakeHandleSource
    var servers: [FakePushServer]
    var loaded = true
    var allowed = true
    var kinds = ["approval", "question", "done", "error"]
    var lang: String? = "ru-RU"
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let defaults: UserDefaults
    let shared: PushShared
    private nonisolated let suite = "dev.bandito.ios.tests.registrar.\(UUID().uuidString)"
    private(set) var registrar: PushRegistrar!

    init(servers: [FakePushServer], handle: String? = "h1", keep: Set<String> = []) {
        self.servers = servers
        device = FakeHandleSource(handle: handle)
        defaults = UserDefaults(suiteName: suite)!
        shared = PushShared(defaults: defaults)
        registrar = PushRegistrar(
            keychain: keychain, device: device, servers: { [unowned self] in self.servers }, isLoaded: { [unowned self] in self.loaded },
            allowed: { [unowned self] in self.allowed }, kinds: { [unowned self] in self.kinds },
            language: { [unowned self] in self.lang }, defaults: defaults, shared: shared, now: { [unowned self] in self.now },
            retryDelay: nil, keepRefs: keep)
    }

    deinit {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

// MARK: the registrar

@MainActor
@Suite struct PushRegistrarTests {
    @Test func aConnectedServerWithPushGetsTheHandleTheKeyAndTheKinds() async throws {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        await h.registrar.reconcile()
        let call = try #require(server.registrations.first)
        #expect(server.registrations.count == 1)
        #expect(call.handle == "h1")
        #expect(call.serverRef == "S1")
        #expect(call.kinds == ["approval", "question", "done", "error"])
        #expect(call.lang == "ru-RU")
        #expect(call.key.count == 32)
        // The key sent is the key the extension will find.
        #expect(h.keychain.key(for: "S1")?.withUnsafeBytes { Data($0) } == call.key)
    }

    @Test func nothingIsRepeatedWhileNothingChanges() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        await h.registrar.reconcile()
        await h.registrar.reconcile()
        await h.registrar.reconcile()
        #expect(server.registrations.count == 1)
        #expect(server.unregisters == 0)
    }

    @Test func aReconnectedServerIsAskedOnceAndNotToldAgainWhenItKeptTheRegistration() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        await h.registrar.reconcile()
        server.isConnected = false
        await h.registrar.reconcile()
        server.isConnected = true
        await h.registrar.reconcile()
        #expect(server.statusCalls == 1)
        #expect(server.registrations.count == 1)
    }

    @Test func aDaemonThatLostTheRegistrationGetsItAgainAfterTheCloudIsAsked() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        await h.registrar.reconcile()
        server.isConnected = false
        await h.registrar.reconcile()
        server.isConnected = true
        server.registeredOnDaemon = false
        h.device.onEnsure = "h2"
        await h.registrar.reconcile()
        #expect(h.device.ensured == [true])
        #expect(server.registrations.map(\.handle) == ["h1", "h2"])
    }

    @Test func aChangeOfKindsLanguageOrHandleRegistersAgain() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        await h.registrar.reconcile()
        h.kinds = ["approval", "question"]
        await h.registrar.reconcile()
        h.lang = "de-DE"
        await h.registrar.reconcile()
        h.device.handle = "h2"
        await h.registrar.reconcile()
        #expect(server.registrations.count == 4)
        #expect(server.registrations[1].kinds == ["approval", "question"])
        #expect(server.registrations[2].lang == "de-DE")
        #expect(server.registrations[3].handle == "h2")
        // The same kinds in another order are the same registration.
        h.kinds = ["question", "approval"]
        await h.registrar.reconcile()
        #expect(server.registrations.count == 4)
    }

    @Test func aDayLaterItRegistersAgain() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        await h.registrar.reconcile()
        h.now = h.now.addingTimeInterval(23 * 3600)
        await h.registrar.reconcile()
        #expect(server.registrations.count == 1)
        h.now = h.now.addingTimeInterval(2 * 3600)
        await h.registrar.reconcile()
        #expect(server.registrations.count == 2)
    }

    @Test func aServerWithoutPushOrNotConnectedIsLeftAlone() async {
        let old = FakePushServer("OLD")
        old.supportsPush = false
        let off = FakePushServer("OFF")
        off.isConnected = false
        let h = RegistrarHarness(servers: [old, off])
        await h.registrar.reconcile()
        #expect(old.registrations.isEmpty && old.unregisters == 0 && old.statusCalls == 0)
        #expect(off.registrations.isEmpty && off.unregisters == 0)
        #expect(h.keychain.serverRefs().isEmpty)
        // It is registered the moment it connects.
        off.isConnected = true
        await h.registrar.reconcile()
        #expect(off.registrations.count == 1)
    }

    @Test func severalServersGetKeysOfTheirOwn() async throws {
        let a = FakePushServer("A")
        let b = FakePushServer("B")
        let h = RegistrarHarness(servers: [a, b])
        await h.registrar.reconcile()
        let keyA = try #require(a.registrations.first?.key)
        let keyB = try #require(b.registrations.first?.key)
        #expect(keyA != keyB)
        #expect(h.keychain.serverRefs() == ["A", "B"])
    }

    @Test func withoutAHandleNothingIsRegisteredUntilTheCloudAnswers() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server], handle: nil)
        await h.registrar.reconcile()
        #expect(h.device.ensured == [false])
        #expect(server.registrations.isEmpty)
        h.device.handle = "h1"
        await h.registrar.reconcile()
        #expect(server.registrations.count == 1)
    }

    @Test func notificationsAllowedLaterThanTheServersConnectedRegistersThen() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        h.allowed = false
        await h.registrar.reconcile()
        #expect(server.registrations.isEmpty)
        h.allowed = true
        await h.registrar.reconcile()
        #expect(server.registrations.count == 1)
    }

    @Test func notificationsOffTellEveryConnectedServerToStopOnce() async {
        let a = FakePushServer("A")
        let b = FakePushServer("B")
        let gone = FakePushServer("C")
        gone.isConnected = false
        let h = RegistrarHarness(servers: [a, b, gone])
        await h.registrar.reconcile()
        h.allowed = false
        await h.registrar.reconcile()
        await h.registrar.reconcile()
        #expect(a.unregisters == 1 && b.unregisters == 1 && gone.unregisters == 0)
        // Allowed again: they register again.
        h.allowed = true
        await h.registrar.reconcile()
        #expect(a.registrations.count == 2 && b.registrations.count == 2)
    }

    @Test func allSwitchesOffMeansNoKindsAndAnUnregister() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        await h.registrar.reconcile()
        h.kinds = []
        await h.registrar.reconcile()
        #expect(server.unregisters == 1)
        #expect(server.registrations.count == 1)
    }

    @Test func aFailedRegistrationIsTriedAgainAtTheNextPass() async {
        let server = FakePushServer("S1")
        server.failRegister = true
        let h = RegistrarHarness(servers: [server])
        await h.registrar.reconcile()
        #expect(server.registrations.isEmpty)
        #expect(h.registrar.lastFingerprint(of: "S1") == nil)
        server.failRegister = false
        await h.registrar.reconcile()
        #expect(server.registrations.count == 1)
    }

    @Test func aKeychainThatRefusesRegistersNothing() async {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server])
        (h.keychain.secrets as? MemoryPushSecrets)?.failure = PushSecretsError(status: -34018)
        await h.registrar.reconcile()
        #expect(server.registrations.isEmpty)
    }

    @Test func aForgottenServerIsToldToStopAndLosesItsKey() async {
        let server = FakePushServer("S1")
        let other = FakePushServer("S2")
        let h = RegistrarHarness(servers: [server, other])
        await h.registrar.reconcile()
        h.shared.noteSeq(5, for: "S1")
        await h.registrar.forgotten(server, unregister: true)
        #expect(server.unregisters == 1)
        #expect(h.keychain.key(for: "S1") == nil)
        #expect(h.keychain.key(for: "S2") != nil)
        #expect(h.registrar.lastFingerprint(of: "S1") == nil)
        #expect(h.shared.lastSeq(for: "S1") == 0)
    }

    @Test func aForgottenServerThatIsNotConnectedOrIsRevokedIsNotCalled() async {
        let off = FakePushServer("S1")
        let revoked = FakePushServer("S2")
        let h = RegistrarHarness(servers: [off, revoked])
        await h.registrar.reconcile()
        off.isConnected = false
        await h.registrar.forgotten(off, unregister: true)
        await h.registrar.forgotten(revoked, unregister: false)
        #expect(off.unregisters == 0 && revoked.unregisters == 0)
        #expect(h.keychain.serverRefs().isEmpty)
    }

    @Test func keysOfServersNoLongerListedAreRemovedOnlyOnceTheListIsRead() async throws {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server], keep: ["TEST"])
        try h.keychain.save(.init(size: .bits256), for: "OLD")
        try h.keychain.save(.init(size: .bits256), for: "TEST")
        h.loaded = false
        await h.registrar.reconcile()
        #expect(h.keychain.serverRefs() == ["OLD", "S1", "TEST"])
        h.loaded = true
        await h.registrar.reconcile()
        #expect(h.keychain.serverRefs() == ["S1", "TEST"])
    }

    /// A reinstall keeps the Keychain but not the defaults: the keys and the old handle are there, the fingerprints are
    /// gone, the token is new. The servers get the new handle at once.
    @Test func afterAReinstallEveryServerGetsTheNewHandle() async throws {
        let server = FakePushServer("S1")
        let h = RegistrarHarness(servers: [server], handle: "old")
        await h.registrar.reconcile()
        let key = server.registrations[0].key
        h.defaults.removeObject(forKey: PushRegistrar.stateKeyPrefix + "S1")
        h.device.handle = "new"
        await h.registrar.reconcile()
        #expect(server.registrations.map(\.handle) == ["old", "new"])
        #expect(server.registrations[1].key == key)
    }

    @Test func kindsFollowTheSettingsAndTheLanguageIsACode() {
        #expect(PushKinds.kinds(approvals: true, answers: true, errors: true) == ["approval", "question", "done", "error"])
        #expect(PushKinds.kinds(approvals: true, answers: false, errors: false) == ["approval", "question"])
        #expect(PushKinds.kinds(approvals: false, answers: true, errors: false) == ["done"])
        #expect(PushKinds.kinds(approvals: false, answers: false, errors: false).isEmpty)
        #expect(PushKinds.language(from: "pt-BR") == "pt-BR")
        #expect(PushKinds.language(from: "zh-Hans-CN") == "zh-Hans-CN")
        #expect(PushKinds.language(from: "en-US@calendar=gregorian") == "en-UScalendargregorian".prefix(16).description)
        #expect(PushKinds.language(from: "") == nil)
        #expect(PushKinds.language(from: nil) == nil)
    }
}

// MARK: the cloud address

final class FakeCloud: PushCloud, @unchecked Sendable {
    // @unchecked: the arrays are guarded by `lock`.
    private let lock = NSLock()
    private var _registered: [(token: String, env: String)] = []
    private var _unregistered: [String] = []
    var next: Result<String, Error> = .success("handle-1")

    var registered: [(token: String, env: String)] { lock.withLock { _registered } }
    var unregistered: [String] { lock.withLock { _unregistered } }

    func register(token: String, env: String) async throws -> String {
        lock.withLock { _registered.append((token, env)) }
        return try next.get()
    }

    func unregister(handle: String) async throws {
        lock.withLock { _unregistered.append(handle) }
    }
}

@MainActor
@Suite struct PushDeviceTests {
    private let token = Data([0xAB, 0x01, 0xFF])

    private func device(
        _ cloud: FakeCloud, keychain: PushKeychain = PushKeychain(secrets: MemoryPushSecrets()), env: String = "sandbox",
        now: @escaping () -> Date = { Date() }
    ) -> PushDevice {
        PushDevice(keychain: keychain, cloud: cloud, environment: { env }, now: now)
    }

    @Test func theTokenInHexGoesToTheCloudAndTheHandleIsKept() async throws {
        let cloud = FakeCloud()
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        let device = device(cloud, keychain: keychain)
        await device.tokenReceived(token)
        #expect(cloud.registered.map(\.token) == ["ab01ff"])
        #expect(cloud.registered.map(\.env) == ["sandbox"])
        #expect(device.handle == "handle-1")
        #expect(keychain.registration() == PushRegistration(token: "ab01ff", env: "sandbox", handle: "handle-1"))
    }

    @Test func theSameTokenAndEnvironmentAreNotSentAgain() async {
        let cloud = FakeCloud()
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        await device(cloud, keychain: keychain).tokenReceived(token)
        // The next launch.
        let next = device(cloud, keychain: keychain)
        await next.tokenReceived(token)
        #expect(cloud.registered.count == 1)
        #expect(next.handle == "handle-1")
    }

    @Test func aNewTokenGetsANewHandleAndTheOldOneIsDropped() async {
        let cloud = FakeCloud()
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        await device(cloud, keychain: keychain).tokenReceived(token)
        cloud.next = .success("handle-2")
        let next = device(cloud, keychain: keychain)
        await next.tokenReceived(Data([1, 2, 3]))
        #expect(cloud.registered.count == 2)
        #expect(cloud.unregistered == ["handle-1"])
        #expect(next.handle == "handle-2")
        #expect(keychain.handle == "handle-2")
    }

    /// A reinstall: the Keychain holds the earlier install's handle for another token. It is not used until the cloud has
    /// answered for the new one.
    @Test func aHandleFromBeforeAReinstallIsNotUsedUntilTheCloudConfirmsTheNewOne() async throws {
        let cloud = FakeCloud()
        cloud.next = .failure(PushCloudError.status(503))
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        try keychain.save(PushRegistration(token: "0ld", env: "sandbox", handle: "stale"))
        let device = device(cloud, keychain: keychain)
        #expect(device.handle == nil)
        await device.tokenReceived(token)
        #expect(device.handle == nil)
        cloud.next = .success("fresh")
        await device.ensureHandle(force: true)
        #expect(device.handle == "fresh")
        #expect(cloud.unregistered == ["stale"])
    }

    @Test func anotherEnvironmentRegistersAgain() async {
        let cloud = FakeCloud()
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        await device(cloud, keychain: keychain, env: "sandbox").tokenReceived(token)
        cloud.next = .success("handle-2")
        await device(cloud, keychain: keychain, env: "production").tokenReceived(token)
        #expect(cloud.registered.map(\.env) == ["sandbox", "production"])
    }

    @Test func aConflictDropsTheOldHandleAndIsNotRetried() async throws {
        let cloud = FakeCloud()
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        try keychain.save(PushRegistration(token: "0ld", env: "sandbox", handle: "stale"))
        cloud.next = .failure(PushCloudError.conflict)
        let device = device(cloud, keychain: keychain, env: "production")
        await device.tokenReceived(token)
        #expect(cloud.registered.count == 1)
        #expect(cloud.unregistered == ["stale"])
        #expect(device.handle == nil)
        #expect(keychain.registration() == nil)
    }

    @Test func withoutTheNetworkNothingIsKeptAndTheNextTryComesLater() async {
        let cloud = FakeCloud()
        cloud.next = .failure(URLError(.notConnectedToInternet))
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let device = device(cloud, now: { clock.value })
        await device.tokenReceived(token)
        #expect(device.handle == nil)
        // Asked again at once (a server connected): not hammered.
        await device.ensureHandle(force: false)
        #expect(cloud.registered.count == 1)
        clock.value = clock.value.addingTimeInterval(61)
        cloud.next = .success("handle-1")
        await device.ensureHandle(force: false)
        #expect(cloud.registered.count == 2)
        #expect(device.handle == "handle-1")
    }

    @Test func aDayLaterTheCloudIsAskedAgain() async {
        let cloud = FakeCloud()
        let keychain = PushKeychain(secrets: MemoryPushSecrets())
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let device = device(cloud, keychain: keychain, now: { clock.value })
        await device.tokenReceived(token)
        clock.value = clock.value.addingTimeInterval(PushDevice.refreshInterval + 1)
        await device.ensureHandle(force: false)
        #expect(cloud.registered.count == 2)
    }

    @Test func theChangeOfTheHandleIsAnnounced() async {
        let cloud = FakeCloud()
        let device = device(cloud)
        var changes = 0
        device.onHandleChange = { changes += 1 }
        await device.tokenReceived(token)
        await device.ensureHandle(force: false)
        #expect(changes == 1)
    }
}

final class Box<T>: @unchecked Sendable {
    // @unchecked: the tests that use it run on one actor.
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: the environment

@Suite struct PushEnvironmentTests {
    /// A provisioning profile is a signed message; the property list sits in it between binary bytes.
    private func profile(aps: String?) -> Data {
        var entitlements = ["application-identifier": "74Q24ZMD7A.dev.bandito.ios"]
        if let aps { entitlements["aps-environment"] = aps }
        let plist = try! PropertyListSerialization.data(
            fromPropertyList: ["Name": "Bandito", "Entitlements": entitlements], format: .xml, options: 0)
        return Data([0x30, 0x82, 0x0A, 0xFF]) + plist + Data([0x00, 0x9F, 0x31])
    }

    @Test func developmentIsSandboxAndProductionIsProduction() {
        #expect(PushEnvironment.environment(provision: profile(aps: "development")) == PushEnvironment.sandbox)
        #expect(PushEnvironment.environment(provision: profile(aps: "production")) == PushEnvironment.production)
    }

    @Test func noProfileOrNoPushEntitlementOrAnUnreadableProfileIsProduction() {
        #expect(PushEnvironment.environment(provision: nil) == PushEnvironment.production)
        #expect(PushEnvironment.environment(provision: profile(aps: nil)) == PushEnvironment.production)
        #expect(PushEnvironment.environment(provision: Data("garbage".utf8)) == PushEnvironment.production)
        #expect(PushEnvironment.environment(provision: Data("<?xml </plist>".utf8)) == PushEnvironment.production)
    }

    @Test func theSimulatorAndDebugBuildsAreSandbox() {
        #expect(PushEnvironment.current() == PushEnvironment.sandbox)
    }
}
