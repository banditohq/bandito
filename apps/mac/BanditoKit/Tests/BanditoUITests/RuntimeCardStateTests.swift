@testable import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

@Suite struct RuntimeCardStateTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func status(
        _ kind: RuntimeKind, installed: Bool, loggedIn: Bool? = nil, version: String? = nil
    ) -> RuntimeStatus {
        RuntimeStatus(kind: kind, installed: installed, version: version, loggedIn: loggedIn, detail: nil)
    }

    private func make(
        _ kind: RuntimeKind = .claude, status: RuntimeStatus?, requestDone: Bool = true,
        remaining: Double? = nil, exhaustedUntil: Date? = nil
    ) -> RuntimeCardState {
        RuntimeCardState.make(
            runtime: kind, status: status, requestDone: requestDone, remaining: remaining,
            exhaustedUntil: exhaustedUntil,
            now: now)
    }

    @Test func checkingOnlyWhileTheStatusRequestRuns() {
        let state = make(status: nil, requestDone: false)
        #expect(state.kind == .checking)
        #expect(state.text == L10n.AgentSheet.statusChecking)
        #expect(!state.showsLimit)
    }

    @Test func aFailedStatusRequestIsNotShownAsChecking() {
        let state = make(status: nil, requestDone: true)
        #expect(state.kind == .unknown)
        #expect(state.text == L10n.AgentSheet.statusUnknown)
    }

    @Test func missingCLIOffersTheInstallGuide() {
        let state = make(.claude, status: status(.claude, installed: false))
        #expect(state.kind == .notInstalled)
        #expect(state.text == L10n.AgentSheet.statusNotInstalled)
        #expect(state.installURL == URL(string: "https://docs.claude.com/en/docs/claude-code/setup"))
        #expect(!state.showsLimit)
    }

    @Test func notLoggedInShowsTheLoginCommand() {
        let claude = make(.claude, status: status(.claude, installed: true, loggedIn: false))
        #expect(claude.kind == .needsLogin)
        #expect(claude.command == "claude")
        #expect(claude.installURL == nil)

        let codex = make(.codex, status: status(.codex, installed: true, loggedIn: false))
        #expect(codex.kind == .needsLogin)
        #expect(codex.command == "codex login")
    }

    @Test func readyWithoutLimitsShowsTheVersionAndNoBar() {
        let state = make(
            .claude, status: status(.claude, installed: true, loggedIn: true, version: "2.0.5 (Claude Code)"))
        #expect(state.kind == .ready)
        #expect(state.text == L10n.AgentSheet.statusReadyVersion(version: "v2.0.5"))
        #expect(!state.showsLimit)
        #expect(state.installURL == nil)
    }

    @Test func readyWhenTheDaemonDoesNotKnowTheLoginState() {
        // The daemon reports `loggedIn` as unknown (nil) for most runtimes: that is not "not signed in".
        let state = make(.codex, status: status(.codex, installed: true, loggedIn: nil, version: "codex-cli 0.46.0"))
        #expect(state.kind == .ready)
        #expect(state.text == L10n.AgentSheet.statusReadyVersion(version: "v0.46.0"))
    }

    @Test func readyWithoutAVersionSaysReady() {
        let state = make(.grok, status: status(.grok, installed: true, loggedIn: true, version: nil))
        #expect(state.kind == .ready)
        #expect(state.text == L10n.AgentSheet.statusReady)
    }

    @Test func limitsShowASignedInStatusAndTheWindowsAreDrawn() {
        let state = make(status: status(.claude, installed: true, loggedIn: true), remaining: 0.6)
        #expect(state.kind == .limits)
        #expect(state.text == L10n.AgentSheet.statusSignedInPlain)
        #expect(state.showsLimit)
    }

    @Test func exhaustedLimitIsItsOwnState() {
        let state = make(status: status(.claude, installed: true, loggedIn: true), remaining: 0)
        #expect(state.kind == .exhausted)
        #expect(state.showsLimit)
    }

    /// "Again" comes with the time the used-up window resets: a week at 100% (5 days) reads "again in 5 d".
    @Test func exhaustedShowsWhenItEnds() {
        let state = make(
            status: status(.claude, installed: true, loggedIn: true), remaining: 0,
            exhaustedUntil: now.addingTimeInterval(5 * 86_400))
        #expect(state.text == L10n.AgentSheet.statusExhausted(time: L10n.Countdown.days(count: 5)))
    }

    /// Without a known reset the line is just "Limit used up": never "again" with no time after it.
    @Test func exhaustedWithoutAResetSaysOnlyLimitUsedUp() {
        let state = make(status: status(.claude, installed: true, loggedIn: true), remaining: 0, exhaustedUntil: nil)
        #expect(state.text == L10n.AgentSheet.statusExhaustedPlain)
    }

    @Test func runtimesGoTwoPerRowAndAnOddOneStaysAlone() {
        let rows = RuntimeCardRows.pairs([.claude, .codex, .grok])
        #expect(rows == [[.claude, .codex], [.grok]])
        #expect(RuntimeCardRows.pairs([.claude, .codex]) == [[.claude, .codex]])
    }

    @Test func versionLabelTakesTheFirstVersionNumber() {
        #expect(RuntimeCardState.versionLabel("2.0.5 (Claude Code)") == "v2.0.5")
        #expect(RuntimeCardState.versionLabel("codex-cli 0.46.0") == "v0.46.0")
        #expect(RuntimeCardState.versionLabel("grok 1.2") == "v1.2")
        #expect(RuntimeCardState.versionLabel("no version here") == nil)
        #expect(RuntimeCardState.versionLabel("") == nil)
        #expect(RuntimeCardState.versionLabel(nil) == nil)
    }

    @Test func installLinksPointAtTheOfficialSetupPages() {
        #expect(RuntimeInstallLinks.url(for: .claude)?.absoluteString == "https://docs.claude.com/en/docs/claude-code/setup")
        #expect(RuntimeInstallLinks.url(for: .codex)?.absoluteString == "https://developers.openai.com/codex/cli")
        #expect(RuntimeInstallLinks.url(for: .grok)?.absoluteString == "https://x.ai/cli")
        #expect(RuntimeInstallLinks.url(for: .api) == nil)
    }
}
