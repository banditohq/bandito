import BanditoKit
import Foundation

/// A final reply of an agent: its thread id (`s<seq>` of the `message.assistant` event) and its text.
struct SpokenReply: Equatable {
    var id: String
    var text: String
}

/// Which agent replies are read aloud. Pure.
enum ReadAloudRules {
    /// The newest final reply, if no message of the person comes after it. Streamed text finalised by something else
    /// (a tool call, the end of a turn without a final message) has the `-s` suffix and is not a final reply.
    static func finalReply(in items: [ThreadItem]) -> SpokenReply? {
        for item in items.reversed() {
            switch item {
            case .assistant(let id, let text, _) where !id.hasSuffix("-s"):
                return SpokenReply(id: id, text: text)
            case .user:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// The reply with this id, anywhere in the thread.
    static func reply(withID id: String, in items: [ThreadItem]) -> SpokenReply? {
        for case .assistant(let itemID, let text, _) in items where itemID == id {
            return SpokenReply(id: itemID, text: text)
        }
        return nil
    }
}

/// Decides, as the thread changes, which final reply to read now. Each reply is read at most once. A reply counts only
/// when a turn was seen running in this view: history that loads on open is never read. A reply that arrives while its
/// turn still runs waits for the turn to end. Reference type, so the view keeps one instance without re-rendering.
final class ReadAloudTracker {
    /// A turn was seen running since the view opened (or since the agent changed).
    private(set) var sawTurn = false
    /// Ids of the replies already read, so none is read twice.
    private(set) var read: Set<String> = []
    /// The reply waiting for its turn to end.
    private(set) var pending: String?

    func reset() {
        sawTurn = false
        read = []
        pending = nil
    }

    /// Call on every change of the thread's items and of its turn state. Returns the reply to read now, if any.
    func observe(items: [ThreadItem], turnRunning: Bool) -> SpokenReply? {
        if turnRunning { sawTurn = true }
        if sawTurn, let reply = ReadAloudRules.finalReply(in: items), !read.contains(reply.id) {
            pending = reply.id
        }
        guard !turnRunning, let id = pending else { return nil }
        pending = nil
        guard let reply = ReadAloudRules.reply(withID: id, in: items) else { return nil }
        read.insert(id)
        return reply
    }
}
