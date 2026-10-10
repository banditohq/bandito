@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Logic behind the typing bubble: what the agent is doing, and how long the turn has run.
@Suite struct AgentActivityTests {
    private func tool(_ id: String, _ name: String, ok: Bool?) -> ThreadItem {
        .tool(ToolRow(callId: id, tool: name, title: name, ok: ok, output: nil))
    }

    private func user(_ text: String, ts: Int64) -> ThreadItem {
        .user(id: "u-\(ts)", text: text, source: .user, from: nil, ts: ts)
    }

    @Test func commandToolsReadAsRunningACommand() {
        #expect(AgentActivity.forTool("Bash") == .command)
        #expect(AgentActivity.forTool("shell") == .command)
    }

    @Test func editToolsReadAsWritingCode() {
        #expect(AgentActivity.forTool("apply_patch") == .coding)
        #expect(AgentActivity.forTool("write_file") == .coding)
    }

    @Test func fileReadToolsReadAsReadingFiles() {
        for name in ["Read", "Grep", "Glob", "LS", "view"] {
            #expect(AgentActivity.forTool(name) == .reading, "\(name)")
        }
    }

    @Test func browserToolsOpenASite() {
        for name in ["browser_click", "browser_navigate", "navigate", "mcp__bandito__browser_snapshot"] {
            #expect(AgentActivity.forTool(name) == .browsing, "\(name)")
        }
    }

    @Test func webToolsSearchTheWeb() {
        #expect(AgentActivity.forTool("WebFetch") == .searching)
        #expect(AgentActivity.forTool("WebSearch") == .searching)
    }

    @Test func unknownNamesAndNearMissesReadAsThinking() {
        #expect(AgentActivity.forTool("") == .thinking)
        #expect(AgentActivity.forTool("crew_send") == .thinking)
        // "thread" contains "read" but is not a file read.
        #expect(AgentActivity.forTool("thread") == .thinking)
    }

    @Test func noToolsMeansThinking() {
        #expect(AgentActivity.current(in: []) == .thinking)
        #expect(AgentActivity.current(in: [user("hi", ts: 1)]) == .thinking)
    }

    @Test func runningToolDecidesTheActivity() {
        let items = [user("fix it", ts: 1), tool("c1", "Bash", ok: nil)]
        #expect(AgentActivity.current(in: items) == .command)
    }

    @Test func finishedToolDoesNotDecideTheActivity() {
        // The edit finished, so the command that is still running decides.
        let items = [tool("c1", "Bash", ok: nil), tool("c2", "apply_patch", ok: true)]
        #expect(AgentActivity.current(in: items) == .command)
        #expect(AgentActivity.current(in: [tool("c3", "Bash", ok: true)]) == .thinking)
    }

    @Test func newestRunningToolWins() {
        let items = [tool("c1", "Bash", ok: nil), tool("c2", "apply_patch", ok: nil)]
        #expect(AgentActivity.current(in: items) == .coding)
    }

    @Test func turnStartIsTheNewestUserMessage() {
        let items: [ThreadItem] = [user("a", ts: 1_000), tool("c1", "Read", ok: true), user("b", ts: 5_000)]
        #expect(AgentActivity.turnStart(in: items) == 5_000)
        #expect(AgentActivity.turnStart(in: [tool("c1", "Read", ok: true)]) == nil)
    }

    @Test func elapsedSecondsCountsWholeSeconds() {
        let now = Date(timeIntervalSince1970: 1_700_000_012.5)
        #expect(AgentActivity.elapsedSeconds(since: 1_700_000_000_000, now: now) == 12)
        #expect(AgentActivity.elapsedSeconds(since: nil, now: now) == nil)
        // A start in the future (clock skew between the daemon and this Mac) never shows a negative time.
        #expect(AgentActivity.elapsedSeconds(since: 1_700_000_020_000, now: now) == 0)
    }

    @Test func elapsedTextIsSecondsThenMinutes() {
        #expect(AgentActivity.elapsedText(seconds: 12).contains("12"))
        #expect(AgentActivity.elapsedText(seconds: 59).contains("59"))
        #expect(AgentActivity.elapsedText(seconds: 60).contains("1"))
        #expect(AgentActivity.elapsedText(seconds: 185).contains("3"))
    }

    @Test func everyActivityHasACaption() {
        let all: [AgentActivity] = [.thinking, .coding, .command, .reading, .browsing, .searching]
        for activity in all {
            #expect(!activity.title.isEmpty)
        }
    }
}
