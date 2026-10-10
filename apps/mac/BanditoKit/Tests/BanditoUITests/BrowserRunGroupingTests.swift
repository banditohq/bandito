@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// Browser calls of an agent in a row are one live card; command calls around them stay command groups.
@Suite struct BrowserRunGroupingTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func tool(_ id: String, _ name: String) -> ThreadItem {
        .tool(ToolRow(callId: id, tool: name, title: name, ok: true, output: nil))
    }

    private func kinds(_ rows: [ThreadRow]) -> [String] {
        rows.map { row in
            switch row {
            case .day: "day"
            case .chapter: "chapter"
            case .item: "item"
            case .toolGroup(let tools): "tools:" + tools.map(\.callId).joined(separator: ",")
            case .browserRun(let tools): "browser:" + tools.map(\.callId).joined(separator: ",")
            }
        }
    }

    @Test func consecutiveBrowserCallsAreOneCard() {
        let items: [ThreadItem] = [
            tool("a", "mcp__bandito__browser_navigate"),
            tool("b", "mcp__bandito__browser_click"),
            tool("c", "mcp__bandito__browser_screenshot"),
        ]
        #expect(kinds(ThreadRows.build(items, calendar: utc)) == ["browser:a,b,c"])
    }

    @Test func commandsBeforeAndAfterStayCommandGroups() {
        let items: [ThreadItem] = [
            tool("a", "Bash"),
            tool("b", "browser_navigate"),
            tool("c", "browser_click"),
            tool("d", "Read"),
        ]
        #expect(kinds(ThreadRows.build(items, calendar: utc)) == ["tools:a", "browser:b,c", "tools:d"])
    }

    @Test func aTextBetweenBrowserCallsSplitsTheCard() {
        let items: [ThreadItem] = [
            tool("a", "browser_navigate"),
            .assistant(id: "r", text: "looking", ts: 1_000),
            tool("b", "browser_click"),
        ]
        #expect(kinds(ThreadRows.build(items, calendar: utc)).filter { $0.hasPrefix("browser") } == ["browser:a", "browser:b"])
    }

    @Test func otherBrowserNamesCount() {
        #expect(WorkbenchRules.isBrowserTool("browser_click"))
        #expect(WorkbenchRules.isBrowserTool("mcp__bandito__browser_open"))
        #expect(!WorkbenchRules.isBrowserTool("Bash"))
    }
}
