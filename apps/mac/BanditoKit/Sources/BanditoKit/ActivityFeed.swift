import Foundation

/// One line of the Activity timeline: a finished turn of an agent, a scheduled run that said something, an error, or an
/// agent created. A quiet run (`turn.quiet`) is not an entry: "nothing new" is hidden from the timeline.
public struct ActivityEntry: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A finished reply of the agent.
        case reply
        /// A finished reply of a scheduled run, with the schedule's name.
        case scheduled(name: String)
        /// An error the agent reported.
        case error
        /// An agent was created: the thread's line for it, already in the person's language.
        case created
    }

    /// The thread row this entry came from (`ThreadItem.id`), unique within its agent.
    public let id: String
    public let agentID: String
    public let kind: Kind
    /// The first line of the reply, the message of the error, or the creation's line; at most
    /// `ActivityFeed.lineLength` characters.
    public let line: String
    /// Unix milliseconds of the row.
    public let ts: Int64
    /// The `seq` of a reply (`ThreadItem.replySeq`); nil for the other kinds.
    public let seq: Int64?
    /// A reply the chat was not read to yet, by the rule of `UnreadReplies`. False for the other kinds.
    public let isUnread: Bool

    public init(id: String, agentID: String, kind: Kind, line: String, ts: Int64, seq: Int64?, isUnread: Bool) {
        self.id = id
        self.agentID = agentID
        self.kind = kind
        self.line = line
        self.ts = ts
        self.seq = seq
        self.isUnread = isUnread
    }
}

/// The Activity timeline of one agent, read from its thread. Pure, so it is tested alone.
public enum ActivityFeed {
    /// The newest entries kept per agent.
    public static let perAgentLimit = 500
    /// The longest line an entry keeps.
    public static let lineLength = 240

    /// The entries of an agent's thread, oldest first, the newest `perAgentLimit` kept. `readSeq` is the seq the chat was
    /// read to (`AgentThreadState`'s read mark): the replies after it are unread.
    public static func entries(agentID: String, items: [ThreadItem], readSeq: Int64) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []
        // The scheduled run whose turn comes next: its reply is the run's, not a plain reply.
        var run: ScheduleRun?
        for item in items {
            switch item {
            case .scheduleRun(_, let scheduled, _, _):
                run = scheduled
            case .user, .quietTurn:
                // A message of the person, or a quiet turn, ends the run: a quiet run says nothing.
                run = nil
            case .assistant(_, let text, let ts):
                let seq = item.replySeq
                let kind: ActivityEntry.Kind = run.map { .scheduled(name: $0.name) } ?? .reply
                run = nil
                entries.append(
                    ActivityEntry(
                        id: item.id, agentID: agentID, kind: kind, line: firstLine(text), ts: ts, seq: seq,
                        isUnread: seq.map { $0 > readSeq } ?? false))
            case .note(let id, let text, let kind, let ts):
                switch kind {
                case .error:
                    entries.append(
                        ActivityEntry(
                            id: id, agentID: agentID, kind: .error, line: firstLine(text), ts: ts, seq: nil,
                            isUnread: false))
                case .crew where !id.hasSuffix("-n"):
                    // The creation notes carry the event's id; the hand-off notes before a crew message end in `-n`.
                    entries.append(
                        ActivityEntry(
                            id: id, agentID: agentID, kind: .created, line: firstLine(text), ts: ts, seq: nil,
                            isUnread: false))
                default:
                    break
                }
            default:
                break
            }
        }
        return Array(entries.suffix(perAgentLimit))
    }

    /// The first non-empty line of a text, trimmed, at most `lineLength` characters. Only the start of a long text is read.
    public static func firstLine(_ text: String) -> String {
        let head = text.prefix(lineLength * 8)
        let line = head.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return String((line ?? "").prefix(lineLength))
    }
}
