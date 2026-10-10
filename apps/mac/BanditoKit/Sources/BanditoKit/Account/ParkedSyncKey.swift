import CryptoKit
import Foundation

/// What `AccountHub.inspect` does with a parked key when this Mac has no live sync key.
public enum ParkedKeyDecision: Equatable, Sendable {
    /// Same account, and the blob opens with the parked key: the key becomes the live key again.
    case restore
    /// The key is useless here: another account's key, or the same account's key that the blob does not open with
    /// (the account was reset from another Mac). It is dropped.
    case discard
    /// No parked key.
    case none
}

/// The sync key of the account this Mac signed out of. A plain sign-out parks the key here instead of deleting it,
/// so signing in again to the same account needs no approval. "Forget this Mac" deletes it.
///
/// Kept in the account store under `keychainAccount`, as JSON `{"account_id": "<id>", "key": "<base64 32 bytes>"}`.
public enum ParkedSyncKey {
    /// Keychain account of the parked key (in the account store, next to `SyncKey.keychainAccount`).
    public static let keychainAccount = "sync-key.parked"

    private struct Record: Codable {
        var accountID: String
        var key: Data

        private enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case key
        }
    }

    /// Stores `key` as the parked key of `accountID`, replacing any parked key.
    public static func park(_ key: SymmetricKey, accountID: String, in store: SecretStore) throws {
        let record = Record(accountID: accountID, key: key.withUnsafeBytes { Data($0) })
        try store.save(try JSONEncoder().encode(record), account: keychainAccount)
    }

    /// The parked key with its account, or nil when there is none. Data that does not parse, or a key that is not
    /// 256 bits, counts as no parked key: the slot is cleared.
    public static func loadParked(from store: SecretStore) throws -> (accountID: String, key: SymmetricKey)? {
        guard let raw = try store.load(account: keychainAccount) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: raw),
            !record.accountID.isEmpty, record.key.count == 32
        else {
            // Damaged data is not a key. Clearing it is best effort: the answer is nil either way.
            try? clearParked(in: store)
            return nil
        }
        return (record.accountID, SymmetricKey(data: record.key))
    }

    /// Removes the parked key, if any.
    public static func clearParked(in store: SecretStore) throws {
        try store.save(nil, account: keychainAccount)
    }

    /// The decision for a sign-in, from what is known: the account of the parked key, the signed-in account, and
    /// whether the sync blob opens with the parked key. Callers ask `opensBlob` only for the same account.
    /// A parked key of another account is dropped: signing in to another account makes it useless here.
    public static func decide(parkedAccountID: String?, currentAccountID: String, opensBlob: Bool) -> ParkedKeyDecision {
        guard let parkedAccountID else { return .none }
        guard parkedAccountID == currentAccountID else { return .discard }
        return opensBlob ? .restore : .discard
    }

    /// What `AccountHub.inspect` may write, decided from what was read: the approval and blob state, whether this
    /// Mac has its live key, a sign-out in progress, and the account of the session. The session is read again right
    /// before the write (`sessionUserID`), and it must be the account the blob belongs to (`blobAccountID`), which
    /// must also be the account of `/me` (`meUserID`). Anything else writes nothing: `.leave`.
    /// On an approved device, a parked key of another account is discarded, with or without a blob. A parked key of
    /// the same account is restored when the blob opens with it, and discarded when it does not (the blob needs to exist).
    public static func restoreDecision(
        approved: Bool, hasBlob: Bool, hasMainKey: Bool, signingOut: Bool,
        parkedAccountID: String?, blobOpensWithParked: Bool,
        blobAccountID: String?, sessionUserID: String?, meUserID: String
    ) -> ParkedRestoreDecision {
        guard approved, !hasMainKey, !signingOut, let parkedAccountID,
            let blobAccountID, let sessionUserID,
            sessionUserID == blobAccountID, meUserID == blobAccountID
        else { return .leave }
        if parkedAccountID != blobAccountID { return .discard }
        guard hasBlob else { return .leave }
        switch decide(parkedAccountID: parkedAccountID, currentAccountID: blobAccountID, opensBlob: blobOpensWithParked) {
        case .restore: return .restore
        case .discard: return .discard
        case .none: return .leave
        }
    }
}

/// What the sign-in does with the parked key, given by `ParkedSyncKey.restoreDecision`.
public enum ParkedRestoreDecision: Equatable, Sendable {
    /// The parked key becomes the live key, and the parked slot is cleared.
    case restore
    /// The parked slot is cleared; the live key stays absent.
    case discard
    /// Nothing is written.
    case leave
}
