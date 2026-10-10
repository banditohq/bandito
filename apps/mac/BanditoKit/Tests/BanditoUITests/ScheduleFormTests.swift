import Foundation
import Testing

@testable import BanditoUI

/// The schedule editor's choices become a cron expression, and an expression reads back into the same choices.
@Suite struct ScheduleFormTests {
    private func form(_ rhythm: ScheduleForm.Rhythm, hour: Int = 9, minute: Int = 0) -> ScheduleForm {
        var f = ScheduleForm()
        f.rhythm = rhythm
        f.hour = hour
        f.minute = minute
        f.prompt = "p"
        return f
    }

    @Test func everyStepMakesClockAlignedCron() {
        var f = form(.every)
        f.step = .minutes(15)
        #expect(f.cron == "*/15 * * * *")
        f.step = .minutes(5)
        #expect(f.cron == "*/5 * * * *")
        f.step = .hours(1)
        #expect(f.cron == "0 * * * *")
        f.step = .hours(6)
        #expect(f.cron == "0 */6 * * *")
        f.step = .hours(12)
        #expect(f.cron == "0 */12 * * *")
    }

    @Test func everyDayAndWeekdaysUseTheTime() {
        #expect(form(.daily, hour: 9, minute: 5).cron == "5 9 * * *")
        #expect(form(.weekdays, hour: 18, minute: 30).cron == "30 18 * * 1-5")
    }

    @Test func pickedDaysAreSortedAndSevenDaysIsEveryDay() {
        var f = form(.days, hour: 8, minute: 0)
        f.weekdays = [5, 1, 3]
        #expect(f.cron == "0 8 * * 1,3,5")
        f.weekdays = Set(0...6)
        #expect(f.cron == "0 8 * * *")
        f.weekdays = []
        #expect(f.cron == nil)
        #expect(!f.canSave)
    }

    @Test func timeOutOfRangeHasNoCron() {
        #expect(form(.daily, hour: 24).cron == nil)
        #expect(form(.weekdays, hour: 9, minute: 60).cron == nil)
    }

    @Test func customNeedsFiveFieldsAndKeepsThemSingleSpaced() {
        var f = form(.custom)
        f.customCron = "  0   9 * *  1-5 "
        #expect(f.cron == "0 9 * * 1-5")
        f.customCron = "0 9 * *"
        #expect(f.cron == nil)
        f.customCron = ""
        #expect(f.cron == nil)
    }

    @Test func savingNeedsAPromptAndAShortTitle() {
        var f = form(.daily)
        f.prompt = "   "
        #expect(!f.canSave)
        f.prompt = "проверяй почту"
        #expect(f.canSave)
        f.title = String(repeating: "я", count: ScheduleForm.titleLimit + 1)
        #expect(!f.canSave)
        f.title = "  Почта  "
        #expect(f.titleOrNil == "Почта")
        f.title = "   "
        #expect(f.titleOrNil == nil)
        #expect(f.canSave)
    }

    @Test func everyCronReadsBackAsEvery() {
        for step in ScheduleForm.Step.all {
            let read = ScheduleForm.reading(cron: step.cron)
            #expect(read.rhythm == .every, "\(step.cron)")
            #expect(read.step == step, "\(step.cron)")
        }
    }

    @Test func clockCronsReadBackAsTheirChoice() {
        let daily = ScheduleForm.reading(cron: "5 9 * * *")
        #expect(daily.rhythm == .daily)
        #expect(daily.hour == 9 && daily.minute == 5)

        let weekdays = ScheduleForm.reading(cron: "30 18 * * 1-5")
        #expect(weekdays.rhythm == .weekdays)
        #expect(weekdays.hour == 18 && weekdays.minute == 30)

        let days = ScheduleForm.reading(cron: "0 8 * * 5,1,3")
        #expect(days.rhythm == .days)
        #expect(days.weekdays == [1, 3, 5])
    }

    @Test func whatTheChoicesCannotSayStaysCustom() {
        for text in ["*/7 * * * *", "0 9 1 * *", "0 9 * * 1,8", "61 9 * * *", "not a cron", "0 0 * * 0-6"] {
            let read = ScheduleForm.reading(cron: text)
            #expect(read.rhythm == .custom, "\(text)")
            #expect(read.customCron == text)
        }
    }

    @Test func everyFormCronRoundTripsThroughReading() {
        var days = form(.days, hour: 7, minute: 45)
        days.weekdays = [0, 6]
        for f in [form(.daily, hour: 0, minute: 0), form(.weekdays, hour: 23, minute: 59), days] {
            guard let cron = f.cron else {
                Issue.record("no cron for \(f.rhythm)")
                continue
            }
            #expect(ScheduleForm.reading(cron: cron).cron == cron)
        }
    }

    @Test func aCustomExpressionTooOftenIsRefusedBeforeTheSave() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9, minute: 0)) ?? Date()
        var f = form(.custom)
        f.prompt = "p"
        f.customCron = "*/2 * * * *"
        #expect(f.tooOften(now: now, calendar: calendar))
        f.customCron = "*/5 * * * *"
        #expect(!f.tooOften(now: now, calendar: calendar))
        // Only a custom expression is checked this way; the offered steps are always five minutes or more.
        var every = form(.every)
        every.step = .minutes(5)
        #expect(!every.tooOften(now: now, calendar: calendar))
    }
}
