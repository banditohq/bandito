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

/// Sign-out in the order that keeps this Mac safe: the sync key and the local session are removed first, and only
/// then is the server asked to end the session. A failed server call is logged and changes nothing locally.
@MainActor
enum SignOutSteps {
    static func run(
        keys: SecretStore, session: Session?, revoke: (Session) async throws -> Void, log: (String) -> Void
    ) async throws {
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

    static func publish(
        local: SyncPayload,
        fetch: () async throws -> SyncPayload?,
        write: (SyncPayload) async throws -> Void
    ) async throws {
        var attempt = 1
        while true {
            let remote = try await fetch() ?? SyncPayload()
            do {
                try await write(ServerSyncPayload.merge(local: local, remote: remote))
                return
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
        didSet { profile.bind(userID: me?.user.id) }
    }

    /// The nickname and avatar colour of the signed-in account on this Mac. Follows `me`.
    let profile = ProfileStore()

    /// Where the session and the sync key are kept. The device keys live in `DeviceIdentityStore`.
    public let keys: SecretStore

    @ObservationIgnored private var watchTask: Task<Void, Never>?

    public init(keys: SecretStore = KeychainStore(service: "dev.bandito.account")) {
        self.keys = keys
        // A stored session is enough to know someone is signed in; no device key is read for that.
        signedIn = ((try? keys.load(account: AccountClient.sessionAccount)) ?? nil) != nil
    }

    /// Reads this device's keys (creating them once) and builds the client. Throws if the Keychain refuses.
    @discardableResult
    public func prepare() async throws -> AccountClient {
        if let client { return client }
        let identity = try await DeviceIdentityStore.shared.load()
        let client = try AccountClient(identity: identity, sessions: keys)
        self.identity = identity
        self.client = client
        syncStore = SyncStore(account: client, keys: keys)
        signedIn = (try? await client.restoreSession()) != nil
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
        let blob = try await client.getSync()
        let hasKey = try SyncKey.load(from: keys) != nil
        return (AccountRoute.decide(approved: true, hasBlob: blob != nil, hasKey: hasKey), me)
    }

    /// The first device of an account: makes the sync key (if there is none) and writes the first, empty blob.
    public func createFirstBlob() async throws {
        _ = try SyncKey.loadOrCreate(from: keys)
        try await syncStore?.push(SyncPayload())
    }

    /// The reset path: the server forgets the sync data and the other devices, then this Mac has a fresh key.
    /// The server refuses it for a session older than ten minutes (`session_too_old`).
    public func recoverAccount() async throws {
        _ = try await prepare()
        _ = try await syncStore?.resetAccount()
        // The old key must not be used for the new history: it is replaced, not reused.
        _ = try SyncKey.rotate(in: keys)
        profile.clear()
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
    }

    /// Signs out: the sync key and the local session go first, then the server is asked to end the session
    /// (best effort, see `SignOutSteps`). The account's nickname and colour leave this Mac too. If the local
    /// steps fail, the error reaches the caller and the account stays as it was.
    public func signOut() async throws {
        let client = try await prepare()
        let session = (try? await client.restoreSession()) ?? nil
        stopWatchingPending()
        try await SignOutSteps.run(
            keys: keys, session: session,
            revoke: { try await client.revoke($0) },
            log: { Logger.account.error("\($0, privacy: .public)") })
        pending = []
        signedIn = false
        profile.clear()
        me = nil
    }

    /// Writes this Mac's ssh servers into the account's sync blob, keeping the other servers and retrying on
    /// conflicts (see `ServerPublishing`). Errors reach the caller.
    public func publishServers(_ configs: [ServerConfig]) async throws {
        _ = try await prepare()
        guard let store = syncStore else { throw AccountHubError.notReady }
        try await ServerPublishing.publish(
            local: ServerSyncPayload.payload(for: configs),
            fetch: { try await store.pull() },
            write: { payload in _ = try await store.push(payload) })
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
