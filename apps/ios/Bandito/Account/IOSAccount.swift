import BanditoKit
import Foundation
import Observation
import OSLog
import UIKit

private let accountLog = Logger(subsystem: "dev.bandito", category: "account")

/// The account of this iPhone: sign-in (GitHub or an email code), approval by a device that already has the sync key, and
/// then the servers that follow the account. The same flows as the Mac's `AccountHub`, on the shared Kit.
///
/// The stage says what the screen shows. Nothing is read from the Keychain until `start()` (the device keys are made on
/// first use), and the network is touched only by the methods that say so.
@MainActor
@Observable
final class IOSAccount {
    /// The one account of the app.
    static let shared = IOSAccount.makeDefault()

    enum Stage: Equatable, Sendable {
        case signedOut
        /// A session is stored and the account is being read.
        case loading
        /// Signed in, but a device that has the sync key must approve this iPhone. `code` is this iPhone's code, to compare
        /// with the approving device's screen.
        case waitingForApproval(code: String)
        /// The key arrived. `code` is the approving device's code: the person confirms it matches that device's screen.
        case confirmSender(code: String)
        /// The codes did not match: the key was dropped and this iPhone left the account.
        case rejected
        /// Approved, but this iPhone has no sync key and no device can hand it over.
        case recoverRequired
        case ready
    }

    private(set) var stage: Stage
    /// The account as the server last said it.
    private(set) var me: Me?
    /// Each server of the account and where this iPhone stands with it.
    private(set) var servers: [AccessServerState] = []
    /// The message of the last failure the person should see; cleared by the next action.
    private(set) var errorText: String?
    /// A short technical line for `errorText` (an error domain and code, never an address or a name), to send to support.
    private(set) var errorDetails: String?
    /// Reads of the account that are running. The loading screen shows a spinner only while this is above zero.
    private(set) var refreshing = 0
    private(set) var github: PhoneGitHubSignIn?
    private(set) var email: PhoneEmailSignIn?

    @ObservationIgnored private let keys: SecretStore
    @ObservationIgnored private let identities: DeviceIdentityStore
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let sink: ServerAccessSink
    /// The servers this iPhone is connected to: it answers the account's requests for them and publishes the ones it was
    /// paired with by a link. Empty in previews and tests that do not need it.
    @ObservationIgnored private let connectedServers: @MainActor () -> [ServerModel]
    @ObservationIgnored private let ledger: AccessLedger
    /// The servers of the account the person removed on this iPhone: not asked for again until shown.
    @ObservationIgnored private let dismissed: DismissedServers
    /// Servers the person removed before the account was known; marked as soon as it is.
    @ObservationIgnored private var queuedDismissals: [ServerConfig] = []
    /// How many are hidden for the signed-in account (the account screen offers to show them).
    private(set) var hiddenCount = 0
    @ObservationIgnored private var responder: AccessResponder?
    @ObservationIgnored private let noiseKeys: ServerNoiseKeyStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let retryDelay: Duration
    /// Seconds between rounds while the fast window is open (a new phone is getting its servers), while a server waits
    /// for the Mac, and otherwise.
    @ObservationIgnored private let fastInterval: Duration
    @ObservationIgnored private let waitingInterval: Duration
    @ObservationIgnored private let idleInterval: Duration
    /// The stretch of fast rounds: opened by a new ready account, by a round that wrote requests and by a return to the
    /// front with a server waiting; lengthened while a server waits, never past its limit in a row.
    @ObservationIgnored private var fastWindow: FastPollWindow
    /// The sleep of the round loop; cancelled to wake the loop when the fast window opens.
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private(set) var cycling = false
    /// A call came while a round ran: one more round follows it.
    @ObservationIgnored private var rerunRequested = false
    /// How many rounds started (tests).
    @ObservationIgnored private(set) var cycleRuns = 0
    /// The clock and the sleep of the round loop; tests drive both.
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    /// True while the fast window is open (the screens say "getting your servers"). Follows the loop.
    private(set) var fastMode = false
    /// A round of the asking side finished since this account became ready.
    private(set) var loadedServers = false

    @ObservationIgnored private(set) var client: AccountClient?
    @ObservationIgnored private var identity: DeviceIdentity?
    @ObservationIgnored private var syncStore: SyncStore?
    @ObservationIgnored private let syncPause: @MainActor () async throws -> Void
    @ObservationIgnored private var requester: AccessRequester?
    @ObservationIgnored private var preparing: Task<AccountClient, Error>?
    @ObservationIgnored private var pending: PendingSyncKey?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var cycleTask: Task<Void, Never>?
    @ObservationIgnored private var signingOut = false
    @ObservationIgnored private var watchingSignIn: Task<Void, Never>?
    /// A preview account (screenshots) never touches the Keychain or the network.
    @ObservationIgnored private var inert = false

    init(
        keys: SecretStore, identities: DeviceIdentityStore, sink: ServerAccessSink, noiseKeys: ServerNoiseKeyStore,
        connectedServers: @escaping @MainActor () -> [ServerModel] = { [] }, ledger: AccessLedger = AccessLedger(),
        dismissed: DismissedServers = DismissedServers(),
        http: HTTPClient = BackgroundHTTPClient(URLSessionHTTPClient(configuration: URLSessionHTTPClient.accountConfiguration())), baseURL: URL = AccountClient.defaultBaseURL,
        deviceName: String = IOSAccount.currentDeviceName(), defaults: UserDefaults = .standard,
        pollInterval: Duration = .seconds(3), retryDelay: Duration = .milliseconds(1500),
        fastInterval: Duration = .seconds(3), waitingInterval: Duration = .seconds(10), idleInterval: Duration = .seconds(60),
        fastWindowLength: TimeInterval = 3 * 60, fastWindowLimit: TimeInterval = 10 * 60,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        syncPause: @escaping @MainActor () async throws -> Void = SyncStore.randomPause
    ) {
        self.keys = keys
        self.identities = identities
        self.sink = sink
        self.noiseKeys = noiseKeys
        self.connectedServers = connectedServers
        self.ledger = ledger
        self.dismissed = dismissed
        self.http = http
        self.baseURL = baseURL
        self.deviceName = deviceName
        self.defaults = defaults
        self.pollInterval = pollInterval
        self.retryDelay = retryDelay
        self.fastInterval = fastInterval
        self.waitingInterval = waitingInterval
        self.idleInterval = idleInterval
        self.now = now
        self.sleep = sleep
        fastWindow = FastPollWindow(length: fastWindowLength, limit: fastWindowLimit)
        self.syncPause = syncPause
        stage = ((try? keys.load(account: AccountClient.sessionAccount)) ?? nil) != nil ? .loading : .signedOut
    }

    private static func makeDefault() -> IOSAccount {
        let secrets = deviceSecrets(service: "dev.bandito.ios.account", fallback: "account-secrets")
        let identitySecrets = deviceSecrets(service: DeviceIdentity.keychainService, fallback: "device-keys")
        let noiseKeys = ServerNoiseKeyStore(secrets: secrets)
        // A server the account hands over goes into the same list as a scanned one, and connects at once.
        let session = AccessSession(
            add: { try ServerSession.shared.add($0) },
            holds: { ServerSession.shared.holds(serverID: $0, phone: $1) })
        let account = IOSAccount(
            keys: secrets, identities: DeviceIdentityStore(secrets: identitySecrets),
            sink: AccountAccessSink(secrets: secrets, session: session, noiseKeys: noiseKeys), noiseKeys: noiseKeys,
            connectedServers: { ServerSession.shared.servers })
        // A server the person removes stays removed; one added again (by any way) lifts the mark.
        ServerSession.shared.onForgotten = { [weak account] in account?.dismiss($0) }
        ServerSession.shared.onAdded = { [weak account] in account?.lift($0) }
        return account
    }

    /// The Keychain; on the Simulator an unsigned build has no Keychain access group and refuses every write, so there a
    /// private file stands in (the same rule as `ServerSession.deviceSecrets`). A device never falls back to a file.
    static func deviceSecrets(service: String, fallback: String) -> SecretStore {
        let keychain = KeychainStore(service: service)
        #if targetEnvironment(simulator)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return SimulatorSecretStore(primary: keychain, fallback: FileSecretStore(directory: base.appending(path: "Bandito/\(fallback)")))
        #else
        return keychain
        #endif
    }

    /// The name other devices show for this iPhone, at most 100 characters.
    static func currentDeviceName() -> String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? "iPhone" : name).prefix(100))
    }

    var signedIn: Bool { stage != .signedOut }

    /// Shows `error` as the screen's message, with its details, and writes its code to the log.
    private func fail(_ error: Error, at place: String = #function) {
        errorText = PhoneAccountMessages.text(for: error)
        errorDetails = PhoneAccountMessages.details(for: error)
        PhoneAccountMessages.record(error, at: place)
    }

    private func clearError() {
        errorText = nil
        errorDetails = nil
    }

    /// Who is signed in, for a line of text: the e-mail, else `@login`, else the name.
    var who: String {
        guard let user = me?.user else { return "" }
        if let email = user.email, !email.isEmpty { return email }
        if let login = user.githubLogin, !login.isEmpty { return "@\(login)" }
        return user.name ?? ""
    }

    // MARK: start

    /// Reads the account when a session is stored. Safe to call again (on every foreground): a ready account just
    /// refreshes, a failure is shown and the next call tries again.
    func start() async {
        guard !inert, stage != .signedOut, stage != .rejected else { return }
        refreshing += 1
        defer { refreshing -= 1 }
        clearError()
        do {
            _ = try await prepare()
            await refresh()
        } catch {
            fail(error)
        }
    }

    /// Builds the client once: the device keys are read (made on the very first use) and the sign-in models are made. Calls
    /// that come while it runs share its result, so the keys are read once.
    @discardableResult
    func prepare() async throws -> AccountClient {
        if let client { return client }
        if let preparing { return try await preparing.value }
        let task = Task { try await self.makeClient() }
        preparing = task
        defer { preparing = nil }
        return try await task.value
    }

    private func makeClient() async throws -> AccountClient {
        let identity = try await identities.load()
        let client = try AccountClient(
            identity: identity, sessions: keys, http: http, baseURL: baseURL,
            device: DeviceDescriptor(name: deviceName, platform: "ios"), retryDelay: retryDelay)
        let store = SyncStore(account: client, keys: keys, defaults: defaults, pause: syncPause)
        self.identity = identity
        self.client = client
        syncStore = store
        responder = AccessResponder(sync: store, account: client, identity: identity, ledger: ledger)
        requester = AccessRequester(
            sync: store, account: client, identity: identity, sink: sink, noiseKeys: noiseKeys, defaults: defaults,
            dismissed: dismissed)
        github = PhoneGitHubSignIn(service: client)
        email = PhoneEmailSignIn(service: client)
        return client
    }

    // MARK: sign-in

    /// Starts the GitHub flow, and moves on when it signs in.
    func startGitHub() async {
        clearError()
        do {
            _ = try await prepare()
        } catch {
            fail(error)
            return
        }
        github?.start()
        watchSignIn()
    }

    func cancelGitHub() {
        github?.cancel()
    }

    /// Sends a code to the typed address.
    func sendEmailCode() async {
        clearError()
        do {
            _ = try await prepare()
        } catch {
            fail(error)
            return
        }
        await email?.sendCode()
    }

    /// Checks the typed code (six digits) and moves on when it signs in.
    func verifyEmailCode() async {
        await email?.verify()
        if email?.signedIn != nil { await finishSignIn() }
    }

    /// Follows the GitHub flow until it ends, then finishes the sign-in. One watcher at a time.
    private func watchSignIn() {
        watchingSignIn?.cancel()
        watchingSignIn = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if case .signedIn = self.github?.state {
                    self.github?.finish()
                    await self.finishSignIn()
                    return
                }
                switch self.github?.state {
                case .expired, .denied, .failed, .none, .idle: return
                default: break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// A sign-in just succeeded: read the account and decide what comes next.
    private func finishSignIn() async {
        email?.finish()
        stage = .loading
        clearError()
        await refresh()
    }

    // MARK: account

    /// Reads the account and moves to the stage it is in. A session the server no longer knows signs this iPhone out here.
    func refresh(firstBlobRetry: Bool = true) async {
        guard let client else { return }
        refreshing += 1
        defer { refreshing -= 1 }
        do {
            let result = try await AccountInspector.inspect(
                client: client, keys: keys, isSigningOut: { [weak self] in self?.signingOut ?? true })
            me = result.me
            flushQueuedDismissals()
            clearError()
            switch result.route {
            case .firstDevice:
                guard let store = syncStore else { return }
                switch try await FirstBlob.write(store: store, client: client, keys: keys) {
                case .written:
                    break
                case .lostRace:
                    // Another device made the first blob: this iPhone asked to be approved, so the route is now
                    // "waiting for approval" (with the code to compare).
                    await refresh(firstBlobRetry: false)
                    return
                case .deferred:
                    // Other devices wrote under every attempt: read the account again (once), then be ready; the next write
                    // goes through `SyncStore.update`.
                    if firstBlobRetry {
                        await refresh(firstBlobRetry: false)
                        return
                    }
                }
                becomeReady()
            case .ready:
                becomeReady()
            case .recoverRequired:
                stopTasks()
                stage = .recoverRequired
            case .waitForApproval:
                guard let identity else { return }
                stage = .waitingForApproval(code: identity.fingerprint)
                startPolling()
            }
        } catch AccountError.api(let code, _) where code == "unauthorized" {
            await dropSession()
        } catch {
            fail(error)
        }
    }

    private func becomeReady() {
        pollTask?.cancel()
        pollTask = nil
        let wasReady = stage == .ready
        stage = .ready
        // A phone that has just become ready, or still has servers waiting, gets its servers within seconds. Every return
        // to the front reads the account again, so an idle one does not open the window each time.
        if !wasReady {
            openFastWindow()
        } else if servers.contains(where: { $0.status == .waitingForMac }), fastWindow.openOnReturn(at: now()) {
            openFastWindow()
        }
        Task { await runCycle() }
    }

    /// Starts (or lengthens) the fast stretch and wakes the round loop, so the sleep it is in does not delay the next round.
    func openFastWindow() {
        fastWindow.open(at: now())
        fastMode = true
        sleeper?.cancel()
    }

    // MARK: approval

    private func startPolling() {
        pollTask?.cancel()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.pollOnce() { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// One look at the server. True when the wait is over: an envelope arrived and opened, or polling failed for good.
    func pollOnce() async -> Bool {
        guard case .waitingForApproval = stage, let client, let identity, let me else { return true }
        do {
            guard let envelope = try await client.myEnvelope() else { return false }
            guard let session = try await client.restoreSession() else { return true }
            let opened = try SyncKey.open(
                envelope: envelope.envelope, with: identity, accountID: session.user.id, deviceID: me.device.id)
            pending = opened
            stage = .confirmSender(code: opened.senderFingerprint)
            return true
        } catch is CancellationError {
            return false
        } catch AccountError.network {
            return false
        } catch AccountError.api(let code, _) where code == "unauthorized" {
            await dropSession()
            return true
        } catch {
            if Task.isCancelled { return false }
            fail(error)
            return true
        }
    }

    /// The person compared the approving device's code with its screen and it matches: the sync key is kept.
    func confirmSender() async {
        guard let pending, case .confirmSender(let code) = stage else { return }
        do {
            let key = try pending.accept(confirmedFingerprint: code)
            try SyncKey.save(key, to: keys)
            self.pending = nil
            clearError()
            stage = .loading
            await refresh()
        } catch {
            fail(error)
        }
    }

    /// The codes differ: the key is dropped and nothing is stored. This iPhone is removed from the account too.
    func refuseSender() async {
        pending = nil
        guard let client, let deviceID = me?.device.id else { return }
        do {
            try await client.deleteDevice(id: deviceID, force: false)
            stage = .rejected
            clearError()
        } catch {
            errorText = PhoneAccountMessages.refuseFailed
            errorDetails = nil
        }
    }

    /// After the refusal screen: the local session goes too.
    func acknowledgeRejected() async {
        await dropSession()
    }

    // MARK: servers

    private var accountID: String? { me?.user.id }

    /// The person removed this server on this iPhone: the account does not bring it back.
    /// When the account is not known yet (signed out, or being read) the mark waits and is written once it is.
    func dismiss(_ config: ServerConfig) {
        guard let accountID else {
            queuedDismissals.append(config)
            if queuedDismissals.count > 50 { queuedDismissals.removeFirst() }
            return
        }
        dismissed.insert(accountID: accountID, serverID: config.id, phone: SyncedPhone(endpoint: config.endpoint))
        hiddenCount = dismissed.count(accountID: accountID)
    }

    /// Writes the marks that waited for the account.
    private func flushQueuedDismissals() {
        guard accountID != nil, !queuedDismissals.isEmpty else { return }
        let waiting = queuedDismissals
        queuedDismissals = []
        for config in waiting { dismiss(config) }
    }

    /// A server was added here: a mark that hid it (by id, or as the same daemon) is lifted.
    func lift(_ config: ServerConfig) {
        let phone = SyncedPhone(endpoint: config.endpoint)
        queuedDismissals.removeAll { waiting in
            waiting.id == config.id || (phone.map { $0.isSameDaemon(as: waiting.endpoint) } ?? false)
        }
        guard let accountID else { return }
        dismissed.lift(accountID: accountID, serverID: config.id, phone: SyncedPhone(endpoint: config.endpoint))
        hiddenCount = dismissed.count(accountID: accountID)
    }

    /// Shows the hidden servers again: the next round asks for them.
    func showHiddenServers() {
        guard let accountID else { return }
        dismissed.clear(accountID: accountID)
        hiddenCount = 0
        openFastWindow()
        Task { await runCycle() }
    }

    /// One round of the asking side: opens grants, asks for the servers it has no token for. Silent on failure: the next
    /// round tries again. A call that comes while a round runs is not lost: one more round runs when it ends.
    func runCycle() async {
        guard stage == .ready, requester != nil else { return }
        if cycling {
            rerunRequested = true
            return
        }
        cycling = true
        defer { cycling = false }
        repeat {
            rerunRequested = false
            cycleRuns += 1
            await runCycleOnce()
        } while rerunRequested && stage == .ready
    }

    private func runCycleOnce() async {
        guard stage == .ready, let requester else { return }
        do {
            // Tell the account about the servers added here by a link, answer what its other devices ask for, then ask for
            // what this iPhone lacks.
            let connected = connectedServers()
            if let store = syncStore, let deviceID = me?.device.id {
                try? await PairedServerPublishing.publish(configs: connected.map(\.config), to: store, deviceID: deviceID)
            }
            if let responder {
                _ = try? await responder.run(servers: connected)
            }
            let states = try await requester.run()
            // The person signed out while the round ran: nothing of it is kept.
            guard stage == .ready else { return }
            servers = states
            loadedServers = true
            noteRound(wroteRequests: requester.lastRunWroteRequests)
            if let accountID { hiddenCount = dismissed.count(accountID: accountID) }
        } catch AccountError.api(let code, _) where code == "unauthorized" {
            await dropSession()
        } catch {
            accountLog.error("Access cycle: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What a finished round says about the pace: requests written mean the Mac has not seen them yet (fast rounds for a
    /// while); a server still waiting keeps a running fast stretch going, within its limit.
    private func noteRound(wroteRequests: Bool) {
        let moment = now()
        if wroteRequests {
            fastWindow.open(at: moment)
            // A loop that fell asleep during this round (it was run by another caller) chose its pace before the window
            // opened: wake it to choose again.
            sleeper?.cancel()
        } else if servers.contains(where: { $0.status == .waitingForMac }) {
            fastWindow.extendIfOpen(at: moment)
        }
        fastMode = fastWindow.isOpen(at: moment)
    }

    /// The cycle runs while the app is in front: every few seconds while the fast window is open, every 10 seconds while a
    /// server waits for the Mac, every minute otherwise. One loop at a time; opening the fast window wakes it.
    func setActive(_ active: Bool) {
        guard !inert else { return }
        cycleTask?.cancel()
        cycleTask = nil
        sleeper?.cancel()
        sleeper = nil
        guard active else {
            fastMode = false
            return
        }
        // Back in front with a server still waiting for the Mac: ask quickly again, unless it has waited at the fast pace
        // for the whole limit not long ago (then the Mac is off, and the slow pace says so).
        if servers.contains(where: { $0.status == .waitingForMac }) { fastWindow.openOnReturn(at: now()) }
        fastMode = fastWindow.isOpen(at: now())
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.stage == .ready { await self.runCycle() }
                if Task.isCancelled { return }
                let sleeper = self.beginSleep()
                await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
            }
        }
    }

    private func beginSleep() -> Task<Void, Never> {
        let fast = fastWindow.isOpen(at: now())
        fastMode = fast
        let waiting = servers.contains { $0.status == .waitingForMac }
        let interval = fast ? fastInterval : (waiting ? waitingInterval : idleInterval)
        let sleep = self.sleep
        let task = Task<Void, Never> { await sleep(interval) }
        sleeper = task
        return task
    }

    /// The account is ready but its servers have not been read yet, and the fast stretch is on.
    var fetchingServers: Bool { stage == .ready && servers.isEmpty && !loadedServers && fastMode }

    // MARK: sign-out

    /// Signs out: the sync key is parked (signing in again to this account needs no approval), the session goes, and the
    /// server is asked to end it. Servers already connected stay. If the local steps fail the error is shown and the
    /// account stays as it was.
    func signOut() async {
        signingOut = true
        defer { signingOut = false }
        stopTasks()
        do {
            let client = try await prepare()
            let session = (try? await client.restoreSession()) ?? nil
            try await SignOutSteps.run(
                keys: keys, session: session, forgetThisMac: false,
                revoke: { try await client.revoke($0) },
                log: { accountLog.error("\($0, privacy: .public)") })
            reset()
        } catch {
            fail(error)
            if case .ready = stage { setActive(true) }
        }
    }

    /// The server does not know this session any more (the device was removed elsewhere): forget it here.
    private func dropSession() async {
        stopTasks()
        try? keys.save(nil, account: AccountClient.sessionAccount)
        try? keys.save(nil, account: SyncKey.keychainAccount)
        reset()
    }

    private func reset() {
        // The hidden servers belong to the account that is leaving; the next one starts with none.
        if let accountID { dismissed.clear(accountID: accountID) }
        hiddenCount = 0
        queuedDismissals = []
        pending = nil
        fastWindow.close()
        fastMode = false
        loadedServers = false
        stage = .signedOut
        me = nil
        servers = []
        clearError()
        github?.cancel()
        email?.finish()
    }

    private func stopTasks() {
        pollTask?.cancel()
        pollTask = nil
        cycleTask?.cancel()
        cycleTask = nil
        sleeper?.cancel()
        sleeper = nil
        watchingSignIn?.cancel()
        watchingSignIn = nil
    }
}

#if DEBUG
extension IOSAccount {
    /// An account in a given stage with no network, for the screenshots (`-account-preview <stage>`) and the previews.
    static func preview(
        stage: Stage, servers: [AccessServerState] = [], who: String = "anna@example.com",
        dismissed: DismissedServers = DismissedServers(), known: Bool = true
    ) -> IOSAccount {
        let account = IOSAccount(
            keys: MemorySecretStore(), identities: DeviceIdentityStore(secrets: MemorySecretStore()),
            sink: AccountAccessSink(secrets: MemorySecretStore(), file: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "preview-access.json")),
            noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()), dismissed: dismissed, deviceName: "iPhone")
        account.inert = true
        account.stage = stage
        account.servers = servers
        if known { account.previewSignIn(who: who) }
        return account
    }
}

extension IOSAccount {
    /// The account becomes known (a sign-in that was read): what waited for it is written.
    func previewSignIn(who: String = "anna@example.com") {
        me = Me(
            user: AccountUser(id: "preview", email: who, name: nil, githubLogin: nil),
            device: DeviceRef(id: "phone", approved: stage != .signedOut), devices: [])
        flushQueuedDismissals()
    }
}

extension IOSAccount {
    /// `-account-preview <signedOut|waiting|confirm|ready|empty>` at launch shows the account screen in that stage with
    /// made-up data, for the screenshots. Release builds ignore it.
    static func previewFromLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> IOSAccount? {
        guard let index = arguments.firstIndex(of: "-account-preview"), arguments.indices.contains(index + 1) else { return nil }
        let ids = (1...4).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
        let phone = SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK")
        switch arguments[index + 1] {
        case "signedOut": return preview(stage: .signedOut)
        case "waiting": return preview(stage: .waitingForApproval(code: "45IU-3YV7-MGPV-EGLY"))
        case "confirm": return preview(stage: .confirmSender(code: "K2QM-7RTD-9WXA-PL4E"))
        case "empty": return preview(stage: .ready)
        case "ready":
            return preview(
                stage: .ready,
                servers: [
                    AccessServerState(id: ids[0], name: "Рабочий сервер", status: .connected, phone: phone),
                    AccessServerState(id: ids[1], name: "Hetzner · агенты", status: .waitingForMac, phone: phone),
                    AccessServerState(id: ids[2], name: "Домашний Mac mini", status: .waitingForMac, phone: phone),
                    AccessServerState(id: ids[3], name: "Тестовый стенд", status: .noRemoteAccess, phone: nil),
                ])
        default: return nil
        }
    }
}
#endif
