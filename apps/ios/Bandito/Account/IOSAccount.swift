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
    private(set) var github: PhoneGitHubSignIn?
    private(set) var email: PhoneEmailSignIn?

    @ObservationIgnored private let keys: SecretStore
    @ObservationIgnored private let identities: DeviceIdentityStore
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let deviceName: String
    @ObservationIgnored private let sink: ServerAccessSink
    @ObservationIgnored private let noiseKeys: ServerNoiseKeyStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pollInterval: Duration

    @ObservationIgnored private(set) var client: AccountClient?
    @ObservationIgnored private var identity: DeviceIdentity?
    @ObservationIgnored private var syncStore: SyncStore?
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
        http: HTTPClient = URLSessionHTTPClient(), baseURL: URL = AccountClient.defaultBaseURL,
        deviceName: String = IOSAccount.currentDeviceName(), defaults: UserDefaults = .standard,
        pollInterval: Duration = .seconds(3)
    ) {
        self.keys = keys
        self.identities = identities
        self.sink = sink
        self.noiseKeys = noiseKeys
        self.http = http
        self.baseURL = baseURL
        self.deviceName = deviceName
        self.defaults = defaults
        self.pollInterval = pollInterval
        stage = ((try? keys.load(account: AccountClient.sessionAccount)) ?? nil) != nil ? .loading : .signedOut
    }

    private static func makeDefault() -> IOSAccount {
        let secrets = deviceSecrets(service: "dev.bandito.ios.account", fallback: "account-secrets")
        let identitySecrets = deviceSecrets(service: DeviceIdentity.keychainService, fallback: "device-keys")
        return IOSAccount(
            keys: secrets, identities: DeviceIdentityStore(secrets: identitySecrets),
            sink: AccountAccessSink(secrets: secrets), noiseKeys: ServerNoiseKeyStore(secrets: secrets))
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
        do {
            _ = try await prepare()
            await refresh()
        } catch {
            errorText = PhoneAccountMessages.text(for: error)
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
            device: DeviceDescriptor(name: deviceName, platform: "ios"))
        let store = SyncStore(account: client, keys: keys, defaults: defaults)
        self.identity = identity
        self.client = client
        syncStore = store
        requester = AccessRequester(
            sync: store, account: client, identity: identity, sink: sink, noiseKeys: noiseKeys, defaults: defaults)
        github = PhoneGitHubSignIn(service: client)
        email = PhoneEmailSignIn(service: client)
        return client
    }

    // MARK: sign-in

    /// Starts the GitHub flow, and moves on when it signs in.
    func startGitHub() async {
        errorText = nil
        do {
            _ = try await prepare()
        } catch {
            errorText = PhoneAccountMessages.text(for: error)
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
        errorText = nil
        do {
            _ = try await prepare()
        } catch {
            errorText = PhoneAccountMessages.text(for: error)
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
        errorText = nil
        await refresh()
    }

    // MARK: account

    /// Reads the account and moves to the stage it is in. A session the server no longer knows signs this iPhone out here.
    func refresh() async {
        guard let client else { return }
        do {
            let result = try await AccountInspector.inspect(
                client: client, keys: keys, isSigningOut: { [weak self] in self?.signingOut ?? true })
            me = result.me
            errorText = nil
            switch result.route {
            case .firstDevice:
                _ = try SyncKey.loadOrCreate(from: keys)
                try await syncStore?.push(SyncPayload())
                try ParkedSyncKey.clearParked(in: keys)
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
            errorText = PhoneAccountMessages.text(for: error)
        }
    }

    private func becomeReady() {
        pollTask?.cancel()
        pollTask = nil
        stage = .ready
        Task { await runCycle() }
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
            errorText = PhoneAccountMessages.text(for: error)
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
            errorText = nil
            stage = .loading
            await refresh()
        } catch {
            errorText = PhoneAccountMessages.text(for: error)
        }
    }

    /// The codes differ: the key is dropped and nothing is stored. This iPhone is removed from the account too.
    func refuseSender() async {
        pending = nil
        guard let client, let deviceID = me?.device.id else { return }
        do {
            try await client.deleteDevice(id: deviceID, force: false)
            stage = .rejected
            errorText = nil
        } catch {
            errorText = PhoneAccountMessages.refuseFailed
        }
    }

    /// After the refusal screen: the local session goes too.
    func acknowledgeRejected() async {
        await dropSession()
    }

    // MARK: servers

    /// One round of the asking side: opens grants, asks for the servers it has no token for. Silent on failure: the next
    /// round tries again.
    func runCycle() async {
        guard stage == .ready, let requester else { return }
        do {
            servers = try await requester.run()
        } catch AccountError.api(let code, _) where code == "unauthorized" {
            await dropSession()
        } catch {
            accountLog.error("Access cycle: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The cycle runs while the app is in front: every 10 seconds while a server waits for the Mac, every minute
    /// otherwise.
    func setActive(_ active: Bool) {
        guard !inert else { return }
        cycleTask?.cancel()
        cycleTask = nil
        guard active else { return }
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.stage == .ready { await self.runCycle() }
                let waiting = self.servers.contains { $0.status == .waitingForMac }
                try? await Task.sleep(for: .seconds(waiting ? 10 : 60))
            }
        }
    }

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
            errorText = PhoneAccountMessages.text(for: error)
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
        pending = nil
        stage = .signedOut
        me = nil
        servers = []
        errorText = nil
        github?.cancel()
        email?.finish()
    }

    private func stopTasks() {
        pollTask?.cancel()
        pollTask = nil
        cycleTask?.cancel()
        cycleTask = nil
        watchingSignIn?.cancel()
        watchingSignIn = nil
    }
}

#if DEBUG
extension IOSAccount {
    /// An account in a given stage with no network, for the screenshots (`-account-preview <stage>`) and the previews.
    static func preview(stage: Stage, servers: [AccessServerState] = [], who: String = "anna@example.com") -> IOSAccount {
        let account = IOSAccount(
            keys: MemorySecretStore(), identities: DeviceIdentityStore(secrets: MemorySecretStore()),
            sink: AccountAccessSink(secrets: MemorySecretStore(), file: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "preview-access.json")),
            noiseKeys: ServerNoiseKeyStore(secrets: MemorySecretStore()), deviceName: "iPhone")
        account.inert = true
        account.stage = stage
        account.servers = servers
        account.me = Me(
            user: AccountUser(id: "preview", email: who, name: nil, githubLogin: nil),
            device: DeviceRef(id: "phone", approved: stage != .signedOut), devices: [])
        return account
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
