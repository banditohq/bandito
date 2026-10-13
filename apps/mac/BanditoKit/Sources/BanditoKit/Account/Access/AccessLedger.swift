import Foundation

/// What the answering device remembers between cycles, on this device only (never in the blob):
/// - which requests it already issued a token for, so a request that comes back (a merge can bring a removed
///   entry back) is not issued twice;
/// - the grant it made but could not write yet, so the token is not lost when the write failed;
/// - the id of the daemon's device row for each issue, so removing a device from the account revokes its rows;
/// - revocations that some server has not seen yet.
///
/// The sealed token is kept only until the grant is written. The ledger holds no plain token.
@MainActor
public final class AccessLedger {
    public struct Issue: Codable, Equatable, Sendable {
        public var accountID: String
        /// The account's id of the device that asked.
        public var deviceID: String
        public var deviceName: String
        public var serverID: String
        /// `AccessRequest.at` of the request that was answered.
        public var requestAt: Int64
        /// The daemon's id of the device row that was issued.
        public var rowID: String
        public var issuedAt: Int64
        /// The grant until it is written to the blob; nil afterwards.
        public var pending: AccessGrant?
    }

    public struct Revocation: Codable, Equatable, Sendable {
        public var accountID: String
        public var deviceID: String
        public var deviceName: String
        public var requestedAt: Int64
        /// Servers that have been cleaned already.
        public var done: [String]
    }

    private struct Stored: Codable {
        var issues: [Issue] = []
        var revocations: [Revocation] = []
    }

    /// The most issues kept; the oldest go first.
    static let maxIssues = 500
    /// A revocation that some server never saw is dropped after this long.
    static let revocationLifetimeMs: Int64 = 30 * 24 * 3600 * 1000

    private let defaults: UserDefaults
    private let key: String
    private var stored: Stored

    public init(defaults: UserDefaults = .standard, key: String = "account.access.ledger.v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    public var issues: [Issue] { stored.issues }
    public var revocations: [Revocation] { stored.revocations }

    func issue(accountID: String, deviceID: String, serverID: String, requestAt: Int64) -> Issue? {
        stored.issues.first {
            $0.accountID == accountID && $0.deviceID == deviceID && $0.serverID == serverID && $0.requestAt == requestAt
        }
    }

    func record(_ issue: Issue) {
        stored.issues.removeAll {
            $0.accountID == issue.accountID && $0.deviceID == issue.deviceID && $0.serverID == issue.serverID
                && $0.requestAt == issue.requestAt
        }
        stored.issues.append(issue)
        if stored.issues.count > Self.maxIssues { stored.issues.removeFirst(stored.issues.count - Self.maxIssues) }
        save()
    }

    /// The grant of `issue` is in the blob now.
    func markWritten(_ issue: Issue) {
        guard let index = stored.issues.firstIndex(where: { $0.rowID == issue.rowID && $0.serverID == issue.serverID }) else {
            return
        }
        stored.issues[index].pending = nil
        save()
    }

    func remove(rowID: String, serverID: String) {
        stored.issues.removeAll { $0.rowID == rowID && $0.serverID == serverID }
        save()
    }

    func addRevocation(_ revocation: Revocation) {
        stored.revocations.removeAll { $0.accountID == revocation.accountID && $0.deviceID == revocation.deviceID }
        stored.revocations.append(revocation)
        save()
    }

    func markDone(_ revocation: Revocation, serverID: String) {
        guard let index = stored.revocations.firstIndex(where: {
            $0.accountID == revocation.accountID && $0.deviceID == revocation.deviceID
        }) else { return }
        if !stored.revocations[index].done.contains(serverID) { stored.revocations[index].done.append(serverID) }
        save()
    }

    func dropOldRevocations(nowMs: Int64) {
        let before = stored.revocations.count
        stored.revocations.removeAll { nowMs - $0.requestedAt > Self.revocationLifetimeMs }
        if stored.revocations.count != before { save() }
    }

    /// Forgets everything of `accountID` (sign-out of the account).
    public func forget(accountID: String) {
        stored.issues.removeAll { $0.accountID == accountID }
        stored.revocations.removeAll { $0.accountID == accountID }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
    }
}
