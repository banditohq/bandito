import Foundation

/// The seq each agent's chat was read to, for one server, kept on this device (UserDefaults). A device has its own
/// marks: what one Mac has read is unread on another.
public struct ReadMarks {
    public let serverID: UUID
    public let defaults: UserDefaults

    public init(serverID: UUID, defaults: UserDefaults = .standard) {
        self.serverID = serverID
        self.defaults = defaults
    }

    /// The seq the chat was read to, or nil when nothing was stored for the agent yet.
    public func seq(for agentID: String) -> Int64? {
        (defaults.object(forKey: key(agentID)) as? NSNumber)?.int64Value
    }

    public func set(_ seq: Int64, for agentID: String) {
        defaults.set(NSNumber(value: seq), forKey: key(agentID))
    }

    private func key(_ agentID: String) -> String {
        "unread.read.\(serverID.uuidString).\(agentID)"
    }
}

/// The unread count of an agent's chat. Pure, so tested alone.
public enum UnreadReplies {
    /// The replies (finished messages of the agent) that came after `readSeq`. The person's own messages, a stream
    /// still running, tools, notes and approvals are not replies. Items are in seq order, so the scan stops at the
    /// first reply that was read.
    public static func count(in items: [ThreadItem], readSeq: Int64) -> Int {
        var count = 0
        for item in items.reversed() {
            guard let seq = item.replySeq else { continue }
            if seq <= readSeq { break }
            count += 1
        }
        return count
    }

    /// The seq a chat counts as read to when no mark was stored: everything in the loaded thread is read, so a first
    /// launch shows no badges for the old history.
    public static func firstSight(stored: Int64?, lastSeq: Int64) -> Int64 {
        stored ?? lastSeq
    }
}
