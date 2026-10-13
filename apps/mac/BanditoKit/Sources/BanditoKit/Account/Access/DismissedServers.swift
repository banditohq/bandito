import Foundation

/// The servers of the account this device was told to leave alone: the person removed them here on purpose, so "servers follow
/// you" must not bring them back. Kept on this device only (never in the blob), per account, so another account starts with none
/// and signing out forgets them. An entry is the server's id in the account and, when known, how to reach it: the same daemon
/// added again under another id (a QR scanned later) lifts the mark.
public struct DismissedServers: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var serverID: UUID
        public var phone: SyncedPhone?

        public init(serverID: UUID, phone: SyncedPhone? = nil) {
            self.serverID = serverID
            self.phone = phone
        }

        func matches(serverID id: UUID, phone other: SyncedPhone?) -> Bool {
            if serverID == id { return true }
            guard let phone, let other else { return false }
            return phone.isSameDaemon(as: other)
        }
    }

    // UserDefaults is documented as thread safe; the struct only holds it.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ accountID: String) -> String { "account.access.dismissed.v1.\(accountID)" }

    public func entries(accountID: String) -> [Entry] {
        guard let data = defaults.data(forKey: key(accountID)), let list = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return list
    }

    private func write(_ list: [Entry], accountID: String) {
        if list.isEmpty {
            defaults.removeObject(forKey: key(accountID))
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key(accountID))
        }
    }

    /// How many servers are hidden for this account.
    public func count(accountID: String) -> Int { entries(accountID: accountID).count }

    /// Whether the server is hidden: by its id, or as the same daemon as a hidden one.
    public func contains(accountID: String, serverID: UUID, phone: SyncedPhone?) -> Bool {
        entries(accountID: accountID).contains { $0.matches(serverID: serverID, phone: phone) }
    }

    /// Hides a server (the person removed it).
    public func insert(accountID: String, serverID: UUID, phone: SyncedPhone?) {
        var list = entries(accountID: accountID).filter { !$0.matches(serverID: serverID, phone: phone) }
        list.append(Entry(serverID: serverID, phone: phone))
        write(list, accountID: accountID)
    }

    /// Lifts the mark of a server that was added again: the same id, or the same daemon.
    public func lift(accountID: String, serverID: UUID, phone: SyncedPhone?) {
        let list = entries(accountID: accountID)
        let kept = list.filter { !$0.matches(serverID: serverID, phone: phone) }
        if kept.count != list.count { write(kept, accountID: accountID) }
    }

    /// Shows every hidden server again.
    public func clear(accountID: String) {
        defaults.removeObject(forKey: key(accountID))
    }
}
