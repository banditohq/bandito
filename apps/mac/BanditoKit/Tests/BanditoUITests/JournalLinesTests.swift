import Foundation
import Testing

@testable import BanditoUI

@Suite struct JournalLinesTests {
    static let utc = TimeZone(identifier: "UTC")!

    @Test func parsesTimeLevelModuleAndMessage() {
        let line = JournalLine("2026-10-09T10:00:03Z ERROR bandito::rpc: failed to open", timeZone: Self.utc)
        #expect(line.time == "10:00:03")
        #expect(line.level == .error)
        #expect(line.module == "bandito::rpc")
        #expect(line.message == "failed to open")
    }

    @Test func fractionalSecondsAndLocalTimeZoneAreShown() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let line = JournalLine("2026-10-09T10:00:03.250Z  WARN files: skipped", timeZone: tokyo)
        #expect(line.time == "19:00:03")
        #expect(line.level == .warn)
        // A word without "::" is not a module: it stays in the message.
        #expect(line.module == nil)
        #expect(line.message == "files: skipped")
    }

    @Test func moduleIsOnlyTakenFromAPathLikeWord() {
        let path = JournalLine("2026-10-09T10:00:03Z ERROR bandito::rpc::read: failed", timeZone: Self.utc)
        #expect(path.module == "bandito::rpc::read")
        #expect(path.message == "failed")
        let plain = JournalLine("2026-10-09T10:00:03Z INFO daemon: started", timeZone: Self.utc)
        #expect(plain.module == nil)
        #expect(plain.message == "daemon: started")
    }

    @Test func brokenStampKeepsTheLevelWithoutATime() {
        let line = JournalLine("not-a-date WARN bandito::x: careful", timeZone: Self.utc)
        #expect(line.time == nil)
        #expect(line.level == .warn)
        #expect(line.module == "bandito::x")
    }

    @Test func lineWithoutModuleKeepsTheWholeMessage() {
        let line = JournalLine("2026-10-09T10:00:03Z INFO daemon started on port 3773", timeZone: Self.utc)
        #expect(line.level == .info)
        #expect(line.module == nil)
        #expect(line.message == "daemon started on port 3773")
    }

    @Test func continuationLinesKeepTheirTextWithoutLevel() {
        let line = JournalLine("  continued warning text", timeZone: Self.utc)
        #expect(line.time == nil)
        #expect(line.level == nil)
        #expect(line.message == "continued warning text")
    }

    @Test func levelWordInsideTheMessageIsNotALevel() {
        let line = JournalLine("2026-10-09T10:00:00Z  INFO a b c ERROR", timeZone: Self.utc)
        #expect(line.level == .info)
        #expect(line.message == "a b c ERROR")
    }

    @Test func identicalConsecutiveLinesCollapseIntoOneRowWithCount() {
        let warning = "2026-10-09T10:00:00Z WARN files: project scan skips /x: Operation not permitted"
        let other = "2026-10-09T10:00:40Z WARN files: project scan skips /y: Operation not permitted"
        let lines = [warning, warning, warning, other, warning]
        let entries = JournalEntry.collapsed(lines, timeZone: Self.utc)
        #expect(entries.map(\.repeats) == [3, 1, 1])
        // The row keeps the newest line of its run, and its id is that line's index.
        #expect(entries[0].id == 2)
        #expect(entries[0].line.time == "10:00:00")
        #expect(entries[1].line.message.hasSuffix("/y: Operation not permitted"))
    }

    @Test func runsWithTheSameTextButDifferentLevelDoNotMerge() {
        let entries = JournalEntry.collapsed(
            ["2026-10-09T10:00:00Z WARN a: x", "2026-10-09T10:00:01Z ERROR a: x"], timeZone: Self.utc)
        #expect(entries.count == 2)
    }

    @Test func emptyLogGivesNoRows() {
        #expect(JournalEntry.collapsed([], timeZone: Self.utc).isEmpty)
    }
}
