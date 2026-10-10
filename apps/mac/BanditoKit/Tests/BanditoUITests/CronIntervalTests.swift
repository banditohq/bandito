import Foundation
import Testing

@testable import BanditoUI

/// The five-minute rule on a custom cron, checked as the daemon checks it: the two runs after a moment.
@Suite struct CronIntervalTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// 2026-10-10 at the given time, in UTC.
    private func at(_ hour: Int, _ minute: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: hour, minute: minute)) ?? Date()
    }

    @Test func everyMinuteAndShortStepsAreTooOften() {
        #expect(CronInterval.gapBetweenNextRuns("* * * * *", after: at(9, 0), calendar: utc) == 1)
        #expect(CronInterval.tooOften("* * * * *", after: at(9, 0), calendar: utc))
        #expect(CronInterval.tooOften("*/2 * * * *", after: at(9, 0), calendar: utc))
        #expect(CronInterval.tooOften("*/4 * * * *", after: at(9, 0), calendar: utc))
    }

    @Test func fiveMinutesAndLongerAreFine() {
        #expect(CronInterval.gapBetweenNextRuns("*/5 * * * *", after: at(9, 0), calendar: utc) == 5)
        #expect(!CronInterval.tooOften("*/5 * * * *", after: at(9, 0), calendar: utc))
        #expect(!CronInterval.tooOften("0 9 * * 1-5", after: at(9, 0), calendar: utc))
        // 2026-10-10 is a Saturday: the next two weekday runs are Monday and Tuesday, a day apart.
        #expect(CronInterval.gapBetweenNextRuns("0 9 * * 1-5", after: at(9, 0), calendar: utc) == 1440)
    }

    @Test func twoRunsAMinuteApartAreTooOften() {
        // From 00:30 the next runs are 01:00 and 01:01.
        #expect(CronInterval.gapBetweenNextRuns("0,1 * * * *", after: at(0, 30), calendar: utc) == 1)
        #expect(CronInterval.tooOften("0,1 * * * *", after: at(0, 30), calendar: utc))
    }

    @Test func sundayIsZeroOrSeven() {
        #expect(CronInterval.gapBetweenNextRuns("0 9 * * 0", after: at(9, 0), calendar: utc) == 7 * 1440)
        #expect(CronInterval.gapBetweenNextRuns("0 9 * * 7", after: at(9, 0), calendar: utc) == 7 * 1440)
    }

    @Test func expressionsThisReaderDoesNotKnowAreLeftToTheDaemon() {
        #expect(CronInterval.gapBetweenNextRuns("not a cron", after: at(9, 0), calendar: utc) == nil)
        #expect(CronInterval.gapBetweenNextRuns("0 9 * * MON", after: at(9, 0), calendar: utc) == nil)
        #expect(CronInterval.gapBetweenNextRuns("0 9 * *", after: at(9, 0), calendar: utc) == nil)
        #expect(!CronInterval.tooOften("0 9 * * MON", after: at(9, 0), calendar: utc))
    }

    @Test func aRunThatNeverComesHasNoGap() {
        // February 30th does not exist.
        #expect(CronInterval.gapBetweenNextRuns("0 9 30 2 *", after: at(9, 0), calendar: utc) == nil)
    }

    @Test func stepsAndRangesOfFieldsAreRead() {
        #expect(CronInterval.parse("*/15", 0...59) == [0, 15, 30, 45])
        #expect(CronInterval.parse("5/20", 0...59) == [5, 25, 45])
        #expect(CronInterval.parse("1-3,10", 0...59) == [1, 2, 3, 10])
        #expect(CronInterval.parse("60", 0...59) == nil)
        #expect(CronInterval.parse("*/0", 0...59) == nil)
    }
}
