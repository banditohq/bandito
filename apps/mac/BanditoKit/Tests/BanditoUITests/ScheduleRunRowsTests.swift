import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

/// A scheduled run and a quiet turn are each one line of the thread: their rows, what the lines say, and that folded
/// they are native rows and open the SwiftUI ones.
@MainActor
@Suite struct ScheduleRunRowsTests {
    private let ts: Int64 = 1_760_000_000_000
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var items: [ThreadItem] {
        [
            .scheduleRun(id: "r1", run: ScheduleRun(id: "s1", name: "Mail", firedAt: ts), prompt: "Check the mail", ts: ts),
            .quietTurn(
                id: "q1", reason: "no mail",
                steps: [.tool(ToolRow(callId: "c1", tool: "bash", title: "ls", ok: true, output: ""))], ts: ts + 1),
        ]
    }

    @Test func theRunAndTheQuietTurnAreOneRowEach() {
        let rows = ThreadRows.build(items, calendar: calendar)
        // The day's divider, then the two lines; the quiet turn's tool call is not a group of the thread.
        #expect(rows.count == 3)
        guard case .day = rows[0], case .item(.scheduleRun) = rows[1], case .item(.quietTurn) = rows[2] else {
            Issue.record("unexpected rows: \(rows)")
            return
        }
        #expect(rows[2].id == "quiet-q1")
    }

    @Test func theRunsLineSaysWhatRanAndWhen() {
        let now = Date(timeIntervalSince1970: TimeInterval(ts) / 1000 + 3600)
        let run = ScheduleRun(id: "s1", name: "Mail", firedAt: ts)
        let clock = Date(timeIntervalSince1970: TimeInterval(ts) / 1000).formatted(date: .omitted, time: .shortened)
        #expect(
            ScheduleRunLine.text(run, now: now, calendar: calendar)
                == "\(L10n.Thread.scheduledRun) · Mail · \(L10n.Thread.ScheduleRun.today(time: clock))")
        // No name: the name is left out; a long one is cut.
        #expect(
            ScheduleRunLine.text(ScheduleRun(id: "s", name: " ", firedAt: ts), now: now, calendar: calendar)
                == "\(L10n.Thread.scheduledRun) · \(L10n.Thread.ScheduleRun.today(time: clock))")
        let long = ScheduleRunLine.text(
            ScheduleRun(id: "s", name: String(repeating: "x", count: 80), firedAt: ts), now: now, calendar: calendar)
        #expect(long.contains(String(repeating: "x", count: ScheduleRunLine.nameLimit - 1) + "…"))
        // The day before.
        let tomorrow = now.addingTimeInterval(86_400)
        #expect(ScheduleRunLine.time(ts, now: tomorrow, calendar: calendar) == L10n.Thread.ScheduleRun.yesterday(time: clock))
    }

    @Test func theQuietLineSaysNothingNewAndWhy() {
        #expect(ScheduleRunLine.quiet(reason: nil) == L10n.Thread.QuietTurn.title)
        #expect(ScheduleRunLine.quiet(reason: "  ") == L10n.Thread.QuietTurn.title)
        #expect(ScheduleRunLine.quiet(reason: "no mail") == L10n.Thread.QuietTurn.title + " · no mail")
        let long = ScheduleRunLine.quiet(reason: String(repeating: "y", count: 100))
        #expect(long.hasSuffix(String(repeating: "y", count: ScheduleRunLine.reasonLimit - 1) + "…"))
    }

    @Test func foldedTheyAreNativeRowsAndOpenTheSwiftUIOnes() {
        for item in items {
            let key = ThreadRowKey(
                row: .item(item), agentName: "Forge", primaryRuntime: "claude", agentID: "a", folder: nil,
                chat: ThreadChat())
            let line = ThreadListLine.row(key, live: false)
            guard case .systemLine(let spec)? = NativeRow.of(line) else {
                Issue.record("a folded line is native: \(item)")
                continue
            }
            ThreadDisclosure.shared.toggle(spec.key)
            #expect(NativeRow.of(line) == nil)
            ThreadDisclosure.shared.toggle(spec.key)
        }
    }
}
