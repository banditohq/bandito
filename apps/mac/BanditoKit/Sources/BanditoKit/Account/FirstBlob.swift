import Foundation

/// The first write of an account's blob, by the first approved device. Two devices that sign in at the same moment can both
/// be approved and both make a key; one wins the blob, the other cannot open it.
@MainActor
public enum FirstBlob {
    public enum Outcome: Equatable, Sendable {
        /// The empty blob is stored under this device's key.
        case written
        /// Other devices kept writing and this device already had its key: nothing is lost, the next round writes.
        case deferred
        /// Another device's blob won. The key made for this attempt is gone and this device asked to be approved again
        /// (`AccountClient.requestKey`): it is pending now and shows the waiting-for-approval screen.
        case lostRace
    }

    /// Makes the key if there is none and writes the empty blob. A key made for this attempt never stays after a failure.
    public static func write(store: SyncStore, client: AccountClient, keys: SecretStore) async throws -> Outcome {
        let hadKey = try SyncKey.load(from: keys) != nil
        _ = try SyncKey.loadOrCreate(from: keys)
        do {
            try await store.push(SyncPayload())
            try ParkedSyncKey.clearParked(in: keys)
            return .written
        } catch {
            if !hadKey { try? keys.save(nil, account: SyncKey.keychainAccount) }
            if case AccountError.network = error { throw error }
            if error is CancellationError { throw error }
            // Is there a blob now? Then it is another device's and this device cannot open it.
            guard let head = try? await client.syncHead(), head.blob != nil else {
                if hadKey, store.isQuietConflict(error) { return .deferred }
                throw error
            }
            if hadKey { return .deferred }
            try await client.requestKey()
            return .lostRace
        }
    }
}
