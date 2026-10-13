import CryptoKit
import Foundation

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

/// Sign-out in the order that keeps this Mac safe. A plain sign-out parks the sync key (so the next sign-in to the
/// same account needs no approval); "forget this Mac" deletes it. The key is parked before anything is removed:
/// if parking fails, the error reaches the caller and nothing is deleted. Then the local key and the session are
/// removed, and only then is the server asked to end the session. A failed server call is logged and changes
/// nothing locally.
@MainActor
public enum SignOutSteps {
    public static func run(
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

/// Reads the account and decides the route of this device (used by the Mac's `AccountHub` and the iPhone's account).
@MainActor
public enum AccountInspector {
    /// The signed-in account and this device's route, from the server (`/me`, the sync blob) and the keys here. A sync
    /// key parked by an earlier sign-out is restored when it opens the account's blob. `isSigningOut` is true from
    /// the first step of a sign-out: nothing is restored meanwhile.
    public static func inspect(
        client: AccountClient, keys: SecretStore, isSigningOut: @MainActor () -> Bool
    ) async throws -> (route: AccountRoute, me: Me) {
        let me = try await client.me()
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
            opens = opensBlob(blob, key: parked.key, accountID: blobAccountID)
        }
        // The session is read again, and the sign-out flag with it. Nothing is awaited after this line: the decision and
        // the writes below run in one step on the main actor. A sign-out that started during the reads above has set
        // the flag or removed the session, and then nothing is written.
        let sessionNow = try await client.restoreSession()?.user.id
        let decision = ParkedSyncKey.restoreDecision(
            approved: true, hasBlob: blob != nil, hasMainKey: hasKey, signingOut: isSigningOut(),
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
    static func opensBlob(_ blob: SyncBlob, key: SymmetricKey, accountID: String) -> Bool {
        let associatedData = SyncKey.blobAssociatedData(accountID: accountID, version: blob.version)
        return (try? SyncKey.openBlob(blob.blob, key: key, associatedData: associatedData)) != nil
    }
}
