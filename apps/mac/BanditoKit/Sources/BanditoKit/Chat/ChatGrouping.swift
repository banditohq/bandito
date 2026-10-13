import Foundation

/// How the chat's rows sit together: how far apart, and which message shows its time. Pure, so tested alone.
public enum ChatGrouping {
    /// The kind of a row, as far as the gaps and the times are concerned.
    public enum Kind: Equatable, Sendable {
        /// A message of the person.
        case mine(ts: Int64?)
        /// A message of the agent, or of a teammate (`from`).
        case theirs(from: String?, ts: Int64?)
        /// A day or a chapter divider.
        case divider
        /// A folded group of tool calls, a note, a line of a run or an answered request.
        case line
        /// A card: an approval, a form, a request to connect, the changes.
        case card
        /// The agent's working row.
        case working
    }

    /// Messages of one sender closer than this follow each other as a group.
    public static let groupGap: Int64 = 5 * 60 * 1000

    /// Whether `a` and `b` are messages of one sender close in time.
    public static func sameGroup(_ a: Kind, _ b: Kind) -> Bool {
        switch (a, b) {
        case (.mine(let x), .mine(let y)):
            return close(x, y)
        case (.theirs(let f, let x), .theirs(let g, let y)):
            return f == g && close(x, y)
        default:
            return false
        }
    }

    private static func close(_ a: Int64?, _ b: Int64?) -> Bool {
        guard let a, let b else { return true }
        return abs(b - a) <= groupGap
    }

    /// The time label is shown under the last message of a group: the next row is not a message of the same sender
    /// within `groupGap`.
    public static func showsTime(_ kind: Kind, next: Kind?) -> Bool {
        guard let next else { return true }
        return !sameGroup(kind, next)
    }

    /// The space above a row, in points.
    public static func spacing(before previous: Kind?, after kind: Kind) -> Double {
        guard let previous else { return 0 }
        if sameGroup(previous, kind) { return 4 }
        switch (previous, kind) {
        case (.divider, _): return 10
        case (_, .divider): return 18
        case (.line, .line): return 6
        case (.line, _), (_, .line): return 12
        case (.card, _), (_, .card): return 12
        case (.working, _), (_, .working): return 10
        default: return 14
        }
    }
}
