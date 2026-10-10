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

/// Sign-out in the order that keeps this Mac safe. A plain sign-out parks the sync key (so the next sign-in to the
/// same account needs no approval); "forget this Mac" deletes it. The key is parked before anything is removed:
/// if parking fails, the error reaches the caller and nothing is deleted. Then the local key and the session are
/// removed, and only then is the server asked to end the session. A failed server call is logged and changes
/// nothing locally.
@MainActor
enum SignOutSteps {
    static func run(
        keys: SecretStore, session: Session?, forgetThisMac: Bool,
        revoke: (Session) async throws -> Void, log: (String) -> Void
    ) async throws {
        if forgetThisMac {
            // Forgetting removes the parked key first, so a failure here leaves the live key and the session in place.
            try ParkedSyncKey.clearParked(in: keys)
        } else if let accountID = session?.user.id {
            // The parked key belongs to the session's account. Without a session there is nothing to park under.
            do {
                if let key = try SyncKey.load(from: keys) {
                    try ParkedSyncKey.park(key, accountID: accountID, in: keys)
                }
            } catch SyncKeyError.invalidKey {
                // A damaged key cannot be parked; the sign-out below removes it like any other key.
            }
        }
        try keys.save(nil, account: SyncKey.keychainAccount)
        try keys.save(nil, account: AccountClient.sessionAccount)
        guard let session else { return }
        do {
            try await revoke(session)
        } catch {
            log("Sign-out: the server did not confirm the end of the session (\(error.localizedDescription)).")
        }
    }
}

/// Publishes this Mac's servers into the sync blob. Fetch, merge, write; on a version conflict the blob is fetched
/// again and merged again, up to `maxAttempts` times. The last conflict is thrown to the caller.
@MainActor
enum ServerPublishing {
    static let maxAttempts = 3

    /// Returns the payload the server stored (the merge of both sides).
    static func publish(
        local: SyncPayload,
        fetch: () async throws -> SyncPayload?,
        write: (SyncPayload) async throws -> SyncPayload
    ) async throws -> SyncPayload {
        var attempt = 1
        while true {
            let remote = try await fetch() ?? SyncPayload()
            do {
                return try await write(ServerSyncPayload.merge(local: local, remote: remote))
            } catch AccountError.conflict(let current) {
                if attempt >= maxAttempts { throw AccountError.conflict(current: current) }
                attempt += 1
            }
        }
    }
}

/// Failures of the account hub that are not from the server.
enum AccountHubError: Error, Equatable, LocalizedError {
    /// A screen used the hub before `prepare` ran.
    case notReady

    var errorDescription: String? {
        L10n.Onboarding.Account.setupFailed
    }
}

/// What a signed-in device does next. Decided from the server state (`/me`, the sync blob) and whether this Mac
/// holds the sync key.
public enum AccountRoute: Equatable, Sendable {
    /// Approved, and the account has no sync data yet: this is the first device. It creates the key and the blob.
    case firstDevice
    /// Approved, with sync data and the key on this Mac: nothing to do.
    case ready
    /// Approved, with sync data but no key here (a reinstall, say). Only a reset makes the account usable again.
    case recoverRequired
    /// Not approved: another device must hand over the sync key.
    case waitForApproval

    public static func decide(approved: Bool, hasBlob: Bool, hasKey: Bool) -> AccountRoute {
        guard approved else { return .waitForApproval }
        if !hasBlob { return .firstDevice }
        return hasKey ? .ready : .recoverRequired
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
    public private(set) var pending: [PendingDevice] = []
    /// Whether a session is stored (someone is signed in on this Mac).
    public private(set) var signedIn = false
    /// The account as the server last said it (`GET /me`): the user and the devices. Nil until it has been read.
    public private(set) var me: Me? {
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
        loadIdentity: @escaping @Sendable () async throws -> DeviceIdentity = { try await DeviceIdentityStore.shared.load() }
    ) {
        self.keys = keys
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
            // The stored session is gone: the profile remembered from the last run is not shown any more.
            profile.forget()
            await avatar.bind(userID: nil)
        }
        return client
    }

    /// Call after a successful sign-in, so the banner and Settings know.
    public func markSignedIn() {
        signedIn = true
    }

    /// The signed-in account and this device's route. Needs a session.
    public func inspect() async throws -> (route: AccountRoute, me: Me) {
        let client = try await prepare()
        let me = try await client.me()
        self.me = me
        guard me.device.approved else {
            return (.waitForApproval, me)
        }
        // The blob belongs to the session's account, as `SyncStore` reads it.
        let blobAccountID = try await client.restoreSession()?.user.id
        let blob = try await client.getSync()
        var hasKey = try SyncKey.load(from: keys) != nil
        var parked: (accountID: String, key: SymmetricKey)?
        if !hasKey {
            parked = try ParkedSyncKey.loadParked(from: keys)
        }
        var opens = false
        if let parked, let blob, let blobAccountID, parked.accountID == blobAccountID {
            opens = Self.opensBlob(blob, key: parked.key, accountID: blobAccountID)
        }
        // The session is read again, and the sign-out flag with it. Nothing is awaited after this line: the decision and
        // the writes below run in one step on the main actor. A sign-out that started during the reads above has set
        // the flag or removed the session, and then nothing is written.
        let sessionNow = try await client.restoreSession()?.user.id
        let decision = ParkedSyncKey.restoreDecision(
            approved: true, hasBlob: blob != nil, hasMainKey: hasKey, signingOut: signingOut,
            parkedAccountID: parked?.accountID, blobOpensWithParked: opens,
            blobAccountID: blobAccountID, sessionUserID: sessionNow, meUserID: me.user.id)
        if let parked, decision == .restore {
            try SyncKey.save(parked.key, to: keys)
            try ParkedSyncKey.clearParked(in: keys)
            hasKey = true
        } else if decision == .discard {
            // Same account, but the blob is not its history any more: the parked key is useless here.
            try ParkedSyncKey.clearParked(in: keys)
        }
        return (AccountRoute.decide(approved: true, hasBlob: blob != nil, hasKey: hasKey), me)
    }

    /// Whether the sync blob opens with `key` for `accountID`, at the blob's version.
    private static func opensBlob(_ blob: SyncBlob, key: SymmetricKey, accountID: String) -> Bool {
        let associatedData = SyncKey.blobAssociatedData(accountID: accountID, version: blob.version)
        return (try? SyncKey.openBlob(blob.blob, key: key, associatedData: associatedData)) != nil
    }

    /// The first device of an account: makes the sync key (if there is none) and writes the first, empty blob.
    public func createFirstBlob() async throws {
        _ = try SyncKey.loadOrCreate(from: keys)
        try await syncStore?.push(SyncPayload())
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
        profile.clear()
        clearPicture()
        me = nil
    }

    /// Writes this Mac's ssh servers into the account's sync blob, keeping the other servers and retrying on
    /// conflicts (see `ServerPublishing`). Errors reach the caller.
    public func publishServers(_ configs: [ServerConfig]) async throws {
        _ = try await prepare()
        guard let store = syncStore else { throw AccountHubError.notReady }
        var local = ServerSyncPayload.payload(for: configs)
        local.profile = await avatar.currentSyncedProfile()
        let stored = try await ServerPublishing.publish(
            local: local,
            fetch: { try await store.pull() },
            write: { payload in try await store.push(payload) })
        try await avatar.apply(stored.profile)
    }

    /// Brings the profile picture in line with the sync blob. A newer copy in the blob is applied on this Mac; a newer
    /// copy here is written to the blob. Equal copies do nothing.
    public func syncProfilePicture() async throws {
        _ = try await prepare()
        guard let store = syncStore else { throw AccountHubError.notReady }
        let remote = try await store.pull()
        if let local = await avatar.currentSyncedProfile(), local.updatedAt > (remote?.profile?.updatedAt ?? 0) {
            let stored = try await ServerPublishing.publish(
                local: SyncPayload(profile: local),
                fetch: { try await store.pull() },
                write: { payload in try await store.push(payload) })
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
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    public func stopWatchingPending() {
        watchTask?.cancel()
        watchTask = nil
    }
}
