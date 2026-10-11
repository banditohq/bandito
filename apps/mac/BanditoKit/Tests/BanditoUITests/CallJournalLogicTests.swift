import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The "Journal" section of a service and the statistics line of its card.
@Suite struct CallJournalLogicTests {
    private func call(_ id: Int64, ok: Bool? = true, error: String? = nil, duration: Int64? = 100) -> ToolCallRecord {
        ToolCallRecord(
            id: id, atMs: 1_000_000 + id, agentId: "a", integration: "svc", tool: "t", durationMs: duration, ok: ok,
            error: error)
    }

    private func page(_ ids: ClosedRange<Int64>) -> [ToolCallRecord] {
        ids.reversed().map { call($0) }
    }

    // MARK: paging

    @Test func aFullFirstPageSaysThereMayBeMore() {
        var journal = CallJournal()
        journal.replace(with: page(71...100))
        #expect(journal.rows.count == CallJournal.pageSize)
        #expect(journal.hasMore)
        #expect(journal.cursor == 71, "the next page is asked for before the last row read")
    }

    @Test func aShortPageEndsTheJournal() {
        var journal = CallJournal()
        journal.replace(with: page(1...5))
        #expect(!journal.hasMore)
        #expect(journal.cursor == 1)
        var empty = CallJournal()
        empty.replace(with: [])
        #expect(!empty.hasMore && empty.cursor == nil)
    }

    @Test func anOlderPageGoesUnderTheRowsWithoutRepeats() {
        var journal = CallJournal()
        journal.replace(with: page(71...100))
        // The page overlaps by one row, as when the journal moved between two asks.
        journal.append(page(41...71))
        #expect(journal.rows.count == 60)
        #expect(Set(journal.rows.map(\.id)).count == 60)
        #expect(journal.rows.map(\.id) == Array((41...100).reversed()))
        #expect(journal.hasMore, "a full page again")
        journal.append(page(1...10))
        #expect(!journal.hasMore)
        #expect(journal.cursor == 1)
    }

    @Test func theFirstPageAgainReplacesTheRows() {
        var journal = CallJournal()
        journal.replace(with: page(71...100))
        journal.append(page(41...70))
        journal.replace(with: page(81...103))
        #expect(journal.rows.first?.id == 103)
        #expect(journal.rows.count == 23)
        #expect(!journal.hasMore)
    }

    // MARK: a row

    @Test func aCallEndsInSuccessAFailureOrNothing() {
        #expect(CallJournalText.outcome(call(1)) == .succeeded)
        #expect(CallJournalText.outcome(call(2, ok: false, error: "rate limited")) == .failed("rate limited"))
        #expect(CallJournalText.outcome(call(3, ok: false, error: "")) == .failed(nil))
        #expect(CallJournalText.outcome(call(4, ok: false)) == .failed(nil))
        #expect(CallJournalText.outcome(call(5, ok: nil, duration: nil)) == .noResult)
    }

    @Test func aDurationReadsInTheUnitThatFits() {
        #expect(CallJournalText.duration(nil) == nil)
        #expect(CallJournalText.duration(-5) == nil)
        #expect(CallJournalText.duration(340)?.contains("340") == true)
        #expect(CallJournalText.duration(1200)?.contains("1.2") == true)
        #expect(CallJournalText.duration(15_400)?.contains("15") == true)
        let long = CallJournalText.duration(125_000)
        #expect(long?.contains("2") == true && long?.contains("5") == true)
    }

    @Test func todayShowsTheClockAndAnotherDayTheDateToo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let noon = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = Int64(noon.timeIntervalSince1970 * 1000)
        let today = CallJournalText.time(ms, now: noon.addingTimeInterval(60), calendar: calendar, locale: locale)
        let other = CallJournalText.time(ms, now: noon.addingTimeInterval(3 * 86_400), calendar: calendar, locale: locale)
        #expect(!today.contains("/"), Comment(rawValue: today))
        #expect(other.contains("/") && other.count > today.count, Comment(rawValue: other))
    }

    @Test func everyDecisionHasItsWord() {
        let words = ToolCallDecision.allCases.map(CallJournalText.decision)
        #expect(Set(words).count == 3)
        #expect(words.allSatisfy { !$0.isEmpty && !$0.contains("market.journal") })
    }

    // MARK: the card's line

    @Test func theLineSaysHowManyCallsAndHowManyErrors() {
        let line = CallJournalText.statsLine(IntegrationCallStats(integration: "svc", calls24h: 12, errors24h: 1))
        #expect(line?.contains("12") == true && line?.contains("1") == true && line?.contains("·") == true)
        let clean = CallJournalText.statsLine(IntegrationCallStats(integration: "svc", calls24h: 3))
        #expect(clean?.contains("3") == true && clean?.contains("·") == false)
    }

    @Test func noCallsInADayMeansNoLine() {
        #expect(CallJournalText.statsLine(nil) == nil)
        #expect(CallJournalText.statsLine(IntegrationCallStats(integration: "svc", calls24h: 0, errors24h: 0, calls7d: 9)) == nil)
    }

    @Test func aFailedTryNamesTheDaemonsSentence() {
        let refused = RPCError(code: -32602, message: "svc is turned off: turn it on to use its tools")
        #expect(ToolTryFailure.message(for: refused).text.contains("turned off"))
        // A lost connection has its usual words, not the daemon's.
        let lost = RPCError(code: RPCError.disconnected, message: "disconnected from the server")
        #expect(!ToolTryFailure.message(for: lost).text.contains("disconnected from the server"))
    }
}
