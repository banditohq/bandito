import Foundation
import Testing

@testable import BanditoKit

/// How a thread is cut into the rows the chat draws: tool calls fold into one group, days and chapters divide.
@Suite struct ChatRowsGroupingTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func tool(_ id: String, ok: Bool? = true) -> ThreadItem {
        .tool(ToolRow(callId: id, tool: "bash", title: "ls \(id)", ok: ok))
    }

    func ms(day: Int, hour: Int = 12) -> Int64 {
        Int64(DateComponents(calendar: Self.calendar, year: 2026, month: 10, day: day, hour: hour).date!.timeIntervalSince1970 * 1000)
    }

    @Test func sevenCommandsInARowAreOneGroup() {
        let items: [ThreadItem] = [.user(id: "s1", text: "go", source: .user, from: nil, ts: ms(day: 12))]
            + (1...7).map { tool("c\($0)") }
            + [.assistant(id: "s2", text: "done", ts: ms(day: 12))]
        let rows = ThreadRows.build(items, calendar: Self.calendar)
        let groups = rows.compactMap { row -> Int? in if case .toolGroup(let tools) = row { return tools.count } else { return nil } }
        #expect(groups == [7])
    }

    @Test func aMessageBetweenCommandsSplitsTheGroup() {
        let items: [ThreadItem] = [
            tool("a"), tool("b"), .assistant(id: "s2", text: "wait", ts: ms(day: 12)), tool("c"),
        ]
        let rows = ThreadRows.build(items, calendar: Self.calendar)
        let sizes = rows.compactMap { row -> Int? in if case .toolGroup(let tools) = row { return tools.count } else { return nil } }
        #expect(sizes == [2, 1])
    }

    @Test func aNewDayGetsADivider() {
        let items: [ThreadItem] = [
            .assistant(id: "s1", text: "one", ts: ms(day: 11)),
            .assistant(id: "s2", text: "two", ts: ms(day: 11, hour: 15)),
            .assistant(id: "s3", text: "three", ts: ms(day: 12)),
        ]
        let rows = ThreadRows.build(items, calendar: Self.calendar)
        let days = rows.filter { if case .day = $0 { return true } else { return false } }
        #expect(days.count == 2)
        #expect(rows.count == 5)
    }

    @Test func aStreamReplacesOnlyItsOwnRow() {
        let base: [ThreadItem] = [.assistant(id: "s1", text: "one", ts: ms(day: 12)), .streaming(text: "He")]
        let rows = ThreadRows.build(base, calendar: Self.calendar)
        let next = [base[0], ThreadItem.streaming(text: "Hello")]
        let replaced = ThreadRows.replacingLast(rows, from: base, to: next)
        #expect(replaced?.count == rows.count)
        #expect(replaced?.last == .item(.streaming(text: "Hello")))
        // A change anywhere else builds the rows again.
        let other = [ThreadItem.assistant(id: "s1", text: "ONE", ts: ms(day: 12)), ThreadItem.streaming(text: "Hello")]
        #expect(ThreadRows.replacingLast(rows, from: base, to: other) == nil)
    }

    @Test func aRunningToolIsAGroupThatIsNotFinished() {
        let rows = ThreadRows.build([tool("a"), tool("b", ok: nil)], calendar: Self.calendar)
        guard case .toolGroup(let tools)? = rows.last else {
            Issue.record("no group")
            return
        }
        #expect(ToolGroupTitle.text(oks: tools.map(\.ok)).isEmpty == false)
        #expect(tools.contains { $0.ok == nil })
    }
}
