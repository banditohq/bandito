import BanditoKit
import BanditoL10n
import CryptoKit
import Foundation
import Observation
import OSLog

extension Logger {
    /// Account events. Never logs tokens, keys or codes.
    static let account = Logger(subsystem: "dev.bandito", category: "account")
}

/// Failures of the account hub that are not from the server.
enum AccountHubError: Error, Equatable, LocalizedError {
    /// A screen used the hub before `prepare` ran.
    case notReady

    var errorDescription: String? {
        L10n.Onboarding.Account.setupFailed
    }
}

/// What the device-approval screens need from the account service. `AccountClient` conforms.
public protocol DeviceApprovalBackend: Sendable {
    func myEnvelope() async throws -> Envelope?
    func pendingDevices() async throws -> [PendingDevice]
    func approve(
        _ device: PendingDevice, confirmedFingerprint: String, syncKey: SymmetricKey, identity: DeviceIdentity
    ) async throws
    func deleteDevice(id: String, force: Bool) async throws
}

extension AccountClient: DeviceApprovalBackend {}

/// The account of this Mac: the client, the sync store, this device's keys and the devices waiting for approval.
/// Built on first use (`prepare`), so nothing touches the Keychain until someone signs in or opens Settings.
@MainActor
@Observable
public final class AccountHub {
    /// Set once `prepare` has run.
    public private(set) var client: AccountClient?
    public private(set) var syncStore: SyncStore?
    public private(set) var identity: DeviceIdentity?
    /// Devices of the account that wait for approval from this device. Refreshed while the app is active.
    public internal(set) var pending: [PendingDevice] = []
    /// Whether a session is stored (someone is signed in on this Mac).
    public private(set) var signedIn = false
    /// The account as the server last said it (`GET /me`): the user and the devices. Nil until it has been read.
    public internal(set) var me: Me? {
        didSet {
            if let id = me?.user.id {
                profile.bind(userID: id)
                Task { await avatar.bind(userID: id) }
            } else if !signedIn {
                // Signed out: nobody is shown, and the next start shows nobody.
                profile.forget()
                Task { await avatar.bind(userID: nil) }
            }
            // Signed in but the account is not read yet (the start, or no network): the user remembered from the last
            // run stays, so the photo and nickname show from this Mac.
        }
    }

    /// The nickname and avatar colour of the signed-in account on this Mac. Follows `me`.
    let profile = ProfileStore()
    /// The profile picture on this Mac, kept in step with the sync blob by `syncProfilePicture`.
    let avatar = ProfileAvatarStore()

    /// Where the session and the sync key are kept. The device keys live in `DeviceIdentityStore`.
    public let keys: SecretStore

    /// The servers this Mac is connected to, for the access cycle. Set by the main window; nil in tests that do not need it.
    @ObservationIgnored public var accessServers: (@MainActor () -> [ServerModel])?
    /// What this Mac last wrote as phone records, so the blob is written again only when they change.
    @ObservationIgnored private var publishedPhones: [UUID: SyncedPhone] = [:]
    @ObservationIgnored private var responder: AccessResponder?
    @ObservationIgnored private var requester: AccessRequester?
    /// The servers of the account the person removed on this Mac: not asked for again until shown.
    @ObservationIgnored private let dismissed: DismissedServers
    /// How many are hidden for the signed-in account (the Account page offers to show them).
    public private(set) var hiddenServerCount = 0
    /// Where the accesses other devices issue for this Mac go (`MacAccessSink`). Set by the main window.
    @ObservationIgnored public var accessSink: (any ServerAccessSink)?
    /// The phone records this Mac last published for its own servers.
    var ownPhoneRecords: [UUID: SyncedPhone] { publishedPhones }
    @ObservationIgnored private let accessLedger = AccessLedger()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// The first `prepare` in progress. Calls that come meanwhile wait for it, so the device identity is read once.
    @ObservationIgnored private var preparing: Task<AccountClient, Error>?
    /// Reads this device's identity. The app reads the Keychain; tests pass their own.
    @ObservationIgnored private let loadIdentity: @Sendable () async throws -> DeviceIdentity
    /// True from the first step of `signOut` until it ends. `inspect` writes no restored key meanwhile: the two
    /// run on the main actor, and the check and the write happen with no suspension between them.
    @ObservationIgnored private var signingOut = false

    public init(
        keys: SecretStore = KeychainStore(service: "dev.bandito.account"),
        dismissed: DismissedServers = DismissedServers(),
        loadIdentity: @escaping @Sendable () async throws -> DeviceIdentity = { try await DeviceIdentityStore.shared.load() }
    ) {
        self.keys = keys
        self.dismissed = dismissed
        self.loadIdentity = loadIdentity
        // A stored session is enough to know someone is signed in; no device key is read for that.
        signedIn = ((try? keys.load(account: AccountClient.sessionAccount)) ?? nil) != nil
        // After a restart the profile of the last signed-in user shows before (and without) the answer of the server.
        if signedIn, let remembered = profile.rememberedUserID {
            profile.bind(userID: remembered)
            Task { await avatar.bind(userID: remembered) }
        }
    }

    /// Reads this device's keys (creating them once) and builds the client. Throws if the Keychain refuses. Calls
    /// made while the first one runs share its result, so the keys are read once and no second client is built.
    @discardableResult
    public func prepare() async throws -> AccountClient {
        if let client { return client }
        if let preparing { return try await preparing.value }
        let task = Task { try await self.makeClient() }
        preparing = task
        defer { preparing = nil }
        return try await task.value
    }

    private func makeClient() async throws -> AccountClient {
        let identity = try await loadIdentity()
        let client = try AccountClient(identity: identity, sessions: keys)
        self.identity = identity
        self.client = client
        syncStore = SyncStore(account: client, keys: keys)
        signedIn = (try? await client.restoreSession()) != nil
        if !signedIn, me == nil {
            // Only the display is dropped; the files and settings of the user stay on this Mac. They are removed by
            // sign-out or reset, not here: the Keychain may be temporarily unavailable, which also reads as no session.
            // The stored session is gone: the profile remembered from the last run is not shown any more.
            profile.forget()
            await avatar.bind(userID: nil)
        }
        return client
    }

    /// Call after a successful sign-in, so the banner and Settings know.
    public func markSignedIn() {
        signedIn = true
        // The round that shows devices to approve and answers access requests runs from now on, not only after a restart.
        startWatchingPending()
    }

    /// The signed-in account and this device's route. Needs a session.
    public func inspect() async throws -> (route: AccountRoute, me: Me) {
        let client = try await prepare()
        let result = try await AccountInspector.inspect(client: client, keys: keys, isSigningOut: { [weak self] in self?.signingOut ?? true })
        self.me = result.me
        return result
    }

    /// The first device of an account: makes the sync key (if there is none) and writes the first, empty blob.
    public func createFirstBlob() async throws {
        let hadKey = hasSyncKey
        _ = try SyncKey.loadOrCreate(from: keys)
        do {
            try await syncStore?.push(SyncPayload())
        } catch {
            // Nothing was written: a key made for this attempt is not the account's key.
            if !hadKey { try? keys.save(nil, account: SyncKey.keychainAccount) }
            throw error
        }
        // A new history: a key parked from an earlier sign-in is not needed any more.
        try ParkedSyncKey.clearParked(in: keys)
    }

    /// The reset path: the server forgets the sync data and the other devices, then this Mac has a fresh key.
    /// The server refuses it for a session older than ten minutes (`session_too_old`).
    public func recoverAccount() async throws {
        _ = try await prepare()
        _ = try await syncStore?.resetAccount()
        // The old key must not be used for the new history: it is replaced, not reused.
        _ = try SyncKey.rotate(in: keys)
        try ParkedSyncKey.clearParked(in: keys)
        profile.clear()
        clearPicture()
    }

    /// Whether this Mac holds the sync key of the signed-in account.
    public var hasSyncKey: Bool {
        (try? SyncKey.load(from: keys)) != nil
    }

    /// Reads the account when someone is signed in, so the sidebar and the profile can show who it is. Silent on
    /// failure: the profile reads it again when it opens.
    public func refreshAccount() async {
        guard signedIn else {
            me = nil
            return
        }
        guard let client = try? await prepare(), let account = try? await client.me() else { return }
        me = account
        try? await syncProfilePicture()
    }

    /// Signs out: the sync key and the local session go first, then the server is asked to end the session
    /// (best effort, see `SignOutSteps`). A plain sign-out parks the sync key, so signing in again to this account
    /// needs no approval; `forgetThisMac` deletes it as well. The account's nickname and colour leave this Mac too.
    /// If the local steps fail, the error reaches the caller and the account stays as it was.
    public func signOut(forgetThisMac: Bool = false) async throws {
        signingOut = true
        defer { signingOut = false }
        let client = try await prepare()
        let session = (try? await client.restoreSession()) ?? nil
        stopWatchingPending()
        try await SignOutSteps.run(
            keys: keys, session: session, forgetThisMac: forgetThisMac,
            revoke: { try await client.revoke($0) },
            log: { Logger.account.error("\($0, privacy: .public)") })
        pending = []
        signedIn = false
        responder = nil
        requester = nil
        publishedPhones = [:]
        if let accountID = session?.user.id {
            accessLedger.forget(accountID: accountID)
            // The hidden servers belong to the account that is leaving; the next one starts with none.
            dismissed.clear(accountID: accountID)
        }
        hiddenServerCount = 0
        profile.clear()
        clearPicture()
        me = nil
    }

    /// Writes this Mac's ssh servers into the account's sync blob, keeping the other servers and retrying on
    /// conflicts (`SyncStore.update`). A conflict that does not clear is left for the next round; other errors reach the caller.
    public func publishServers(_ configs: [ServerConfig], phones: [UUID: SyncedPhone]? = nil) async throws {
        _ = try await prepare()
        guard let store = syncStore else { throw AccountHubError.notReady }
        let records = phones ?? publishedPhones
        var local = ServerSyncPayload.payload(for: configs, phones: records, localDeviceID: me?.device.id)
        local.profile = await avatar.currentSyncedProfile()
        let stored: SyncPayload
        do {
            stored = try await store.update { payload in payload = ServerSyncPayload.merge(local: local, remote: payload) }
        } catch where store.isQuietConflict(error) {
            // Other devices keep writing: the next round tries again (`publishedPhones` is not updated, so it does).
            Logger.account.notice("Publish servers: the blob changed under every attempt, left for the next round.")
            return
        }
        try await avatar.apply(stored.profile)
        if let phones { publishedPhones = phones }
    }

    /// One round of "servers follow you": writes the phone records of the servers this Mac is connected to when they
    /// changed, then answers the requests of the account's other devices (`AccessResponder`). Silent on failure: the
    /// next round tries again. Does nothing without a session, a sync key or `accessServers`.
    public func runAccessCycle(configs: [ServerConfig]) async {
        guard signedIn, hasSyncKey, let provider = accessServers else { return }
        do {
            _ = try await prepare()
            guard let store = syncStore, let client, let identity else { return }
            let servers = provider()
            let phones = await PhoneRecords.collect(from: servers)
            if !phones.isEmpty, phones != publishedPhones {
                try await publishServers(configs, phones: phones)
            }
            let responder = self.responder ?? AccessResponder(
                sync: store, account: client, identity: identity, ledger: accessLedger)
            self.responder = responder
            let outcome = try await responder.run(servers: servers)
            if outcome.updateNeeded > 0 {
                Logger.account.notice("Access: \(outcome.updateNeeded) request(s) wait: bandito.dev does not list device keys yet, update the account service.")
            }
            // The other way: servers the account has (added on the iPhone) that this Mac does not.
            if let sink = accessSink {
                let asking = self.requester ?? AccessRequester(
                    sync: store, account: client, identity: identity, sink: sink,
                    noiseKeys: ServerNoiseKeyStore(secrets: keys), dismissed: dismissed)
                self.requester = asking
                _ = try await asking.run()
            }
        } catch {
            Logger.account.error("Access cycle: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var currentAccountID: String? { me?.user.id ?? profile.rememberedUserID }

    /// The person removed this server on this Mac: the account does not bring it back.
    public func dismiss(_ config: ServerConfig) {
        guard signedIn, let accountID = currentAccountID else { return }
        dismissed.insert(
            accountID: accountID, serverID: config.id,
            phone: SyncedPhone(endpoint: config.endpoint) ?? publishedPhones[config.id])
        hiddenServerCount = dismissed.count(accountID: accountID)
    }

    /// A server was added here: a mark that hid it (by id, or as the same daemon) is lifted.
    public func lift(_ config: ServerConfig) {
        guard let accountID = currentAccountID else { return }
        dismissed.lift(accountID: accountID, serverID: config.id, phone: SyncedPhone(endpoint: config.endpoint))
        hiddenServerCount = dismissed.count(accountID: accountID)
    }

    /// Reads how many servers are hidden (the Account page shows the button while there are some).
    public func refreshHiddenCount() {
        hiddenServerCount = currentAccountID.map { dismissed.count(accountID: $0) } ?? 0
    }

    /// Shows the hidden servers again: the next round asks for them.
    public func showHiddenServers() {
        guard let accountID = currentAccountID else { return }
        dismissed.clear(accountID: accountID)
        hiddenServerCount = 0
        requestAccessCycle()
    }

    /// Runs a round of the access cycle now, without waiting for the next tick: after the cloud was switched on or off, so
    /// the account's other devices see the way in (or its loss) within seconds.
    public func requestAccessCycle() {
        guard signedIn, let configs = accessServers?().map(\.config) else { return }
        Task { await runAccessCycle(configs: configs) }
    }

    /// A device left the account: runs a round now, which revokes the rows this Mac issued to it (the round compares what
    /// this Mac issued with the account's device list, so a removal from another device is handled the same way).
    public func revokeAccess(of device: AccountDevice) async {
        guard let configs = accessServers?().map(\.config) else { return }
        await runAccessCycle(configs: configs)
    }

    /// Brings the profile picture in line with the sync blob. A newer copy in the blob is applied on this Mac; a newer
    /// copy here is written to the blob. Equal copies do nothing.
    public func syncProfilePicture() async throws {
        _ = try await prepare()
        guard let store = syncStore else { throw AccountHubError.notReady }
        let remote = try await store.pull()
        if let local = await avatar.currentSyncedProfile(), local.updatedAt > (remote?.profile?.updatedAt ?? 0) {
            let stored: SyncPayload
            do {
                stored = try await store.update { payload in
                    payload = ServerSyncPayload.merge(local: SyncPayload(profile: local), remote: payload)
                }
            } catch where store.isQuietConflict(error) {
                Logger.account.notice("Profile picture: the blob changed under every attempt, left for the next round.")
                return
            }
            try await avatar.apply(stored.profile)
        } else {
            try await avatar.apply(remote?.profile)
        }
    }

    /// Removes this user's picture from this Mac. A failure is logged: the account is already signed out or reset.
    private func clearPicture() {
        do {
            try avatar.clear()
        } catch {
            Logger.account.error("Profile picture: could not remove it from this Mac (\(error.localizedDescription, privacy: .public)).")
        }
    }

    /// Asks for devices waiting for approval. Silent on failure: a device that is not approved yet is not allowed to.
    public func refreshPending() async {
        guard let client else { return }
        if let devices = try? await client.pendingDevices() {
            pending = devices
        }
    }

    /// Refreshes the pending list every 30 seconds until stopped. The Task holds the hub weakly.
    /// Does nothing without a session: nobody can ask for pending devices then.
    public func startWatchingPending() {
        guard watchTask == nil, signedIn else { return }
        // Weak capture, and the hub is held only for the refresh itself: while the Task sleeps, nothing keeps it alive.
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshPending()
                if let hub = self, let configs = hub.accessServers?().map(\.config) {
                    await hub.runAccessCycle(configs: configs)
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    public func stopWatchingPending() {
        watchTask?.cancel()
        watchTask = nil
    }
}
