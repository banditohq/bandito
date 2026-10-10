import BanditoKit
import BanditoL10n
import Foundation

/// What the agent is doing while its turn runs, for the typing bubble at the end of the thread.
enum AgentActivity: Equatable {
    case thinking
    case coding
    case command
    case reading
    case browsing
    case searching

    /// The activity a running tool call stands for: commands, edits, file reads, the browser, web search. Any other
    /// tool reads as thinking.
    static func forTool(_ tool: String) -> AgentActivity {
        let name = tool.lowercased()
        if name.contains("bash") || name.contains("shell") || name.contains("exec") || name.contains("terminal") {
            return .command
        }
        if name.contains("patch") || name.contains("edit") || name.contains("write") {
            return .coding
        }
        if ["read", "grep", "glob", "ls", "view"].contains(name) {
            return .reading
        }
        if name.hasPrefix("browser_") || name == "navigate" || name.hasPrefix("mcp__bandito__browser") {
            return .browsing
        }
        if name == "webfetch" || name == "websearch" {
            return .searching
        }
        return .thinking
    }

    /// The newest tool call that has not finished decides the activity; with none running, the agent is thinking.
    static func current(in items: [ThreadItem]) -> AgentActivity {
        for item in items.reversed() {
            if case .tool(let row) = item, row.ok == nil {
                return forTool(row.tool)
            }
        }
        return .thinking
    }

    /// The localized caption of this activity.
    var title: String {
        switch self {
        case .thinking: L10n.Team.Activity.thinking
        case .coding: L10n.Team.Activity.coding
        case .command: L10n.Team.Activity.command
        case .reading: L10n.Team.Activity.reading
        case .browsing: L10n.Team.Activity.browsing
        case .searching: L10n.Team.Activity.searching
        }
    }

    /// Whole seconds since `startMs` (Unix ms) at `now`, never negative. `nil` without a start.
    static func elapsedSeconds(since startMs: Int64?, now: Date) -> Int? {
        guard let startMs else { return nil }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return max(0, Int((nowMs - startMs) / 1000))
    }

    /// "12 s" under a minute, then whole minutes: "3 min".
    static func elapsedText(seconds: Int) -> String {
        seconds < 60 ? L10n.Team.Activity.seconds(count: seconds) : L10n.Team.Activity.minutes(count: seconds / 60)
    }
}
