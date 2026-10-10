import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

/// What the usage surfaces say: a runtime's error in plain words, the Grok line, and when the limits were received.
@Suite struct UsageMessagesTests {
    @Test func aLoginErrorBecomesSignInNeededWithTheCommand() {
        let problem = UsageProblem.make(runtime: "codex", raw: "codex account authentication required to read rate limits")
        #expect(problem.kind == .needsLogin)
        #expect(problem.title == L10n.AgentSheet.statusNeedsLogin)
        #expect(problem.loginCommand == "codex login")
        #expect(problem.raw == "codex account authentication required to read rate limits")
    }

    @Test func aMissingCLIBecomesNotInstalled() {
        let problem = UsageProblem.make(runtime: "claude", raw: "claude: command not found")
        #expect(problem.kind == .notInstalled)
        #expect(problem.title == L10n.AgentSheet.statusNotInstalled)
        #expect(problem.loginCommand == nil)
    }

    @Test func anUnknownErrorKeepsTheRawTextForTheTooltipOnly() {
        let problem = UsageProblem.make(runtime: "codex", raw: "codex: rate limits request timed out")
        #expect(problem.kind == .unknown)
        #expect(problem.title == L10n.Usage.Error.unknown)
        #expect(problem.loginCommand == nil)
        #expect(problem.raw == "codex: rate limits request timed out")
    }

    @Test func theLoginCommandIsTheRuntimesOwn() {
        #expect(UsageProblem.loginCommand(runtime: "claude") == "claude")
        #expect(UsageProblem.loginCommand(runtime: "grok") == "grok login --device-auth")
        #expect(UsageProblem.loginCommand(runtime: "unknown") == nil)
    }

    @Test func grokSaysItDoesNotReportLimits() {
        #expect(UsageCards.waitingText("grok") == L10n.Usage.grokNoLimits)
        #expect(UsageCards.waitingText("claude") == L10n.Usage.claudeWaitsForReply)
        #expect(UsageCards.waitingText("codex") == L10n.Usage.noLimitsYet)
    }

    @Test func updatedTextIsRelativeAndHumanRecent() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let ru = Locale(identifier: "ru_RU")
        let now = CountdownTests.date(2026, 10, 10, 15, 0)

        func text(_ updated: Date) -> String {
            UsagePopover.updatedText(updated, now: now, calendar: utc, locale: ru)
        }
        #expect(text(now.addingTimeInterval(-30)) == L10n.Usage.Updated.justNow)
        #expect(text(now.addingTimeInterval(-5 * 60)) == L10n.Common.minutesAgo(count: 5))
        #expect(text(now.addingTimeInterval(-2 * 3600)) == L10n.Usage.Updated.hoursAgo(count: 2))
        #expect(text(CountdownTests.date(2026, 10, 9, 18, 40)) == L10n.Usage.Updated.yesterday(time: "18:40"))
        // An older date reads as the date and the time; the exact date wording is the locale's.
        let older = text(CountdownTests.date(2026, 10, 1, 9, 5))
        #expect(older.hasSuffix("09:05"))
        #expect(older != L10n.Usage.Updated.yesterday(time: "09:05"))
        #expect(UsagePopover.updatedText(nil, now: now) == L10n.Common.now)
    }
}
