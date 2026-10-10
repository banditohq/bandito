import BanditoL10n
import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct UsageRowsTests {
    private func status(_ kind: RuntimeKind, installed: Bool) -> RuntimeStatus {
        RuntimeStatus(kind: kind, installed: installed, version: nil, loggedIn: nil, detail: nil)
    }

    private func signedOut(_ kind: RuntimeKind) -> RuntimeStatus {
        RuntimeStatus(kind: kind, installed: true, version: nil, loggedIn: false, detail: nil)
    }

    private func card(_ runtime: String) -> UsageCard {
        UsageCard(
            runtime: runtime, name: UsageCards.displayName(runtime), plan: nil, color: .peach, who: nil, windows: [])
    }

    @Test func installedRuntimeWithoutLimitsGetsAWaitingLine() {
        let rows = UsageRow.make(
            cards: [], runtimes: [status(.claude, installed: true), status(.codex, installed: true)], errors: [:])
        #expect(rows.map(\.id) == ["claude", "codex"])
        guard case .waiting(_, _, let text, let problem) = rows[0] else {
            Issue.record("claude should wait for its first reply")
            return
        }
        #expect(text == L10n.Usage.claudeWaitsForReply)
        #expect(problem == nil)
    }

    @Test func notInstalledRuntimeIsLeftOut() {
        let rows = UsageRow.make(cards: [card("grok")], runtimes: [status(.grok, installed: false)], errors: [:])
        #expect(rows.isEmpty)
    }

    @Test func noInstalledRuntimeMeansNoRows() {
        let rows = UsageRow.make(
            cards: [], runtimes: [status(.claude, installed: false), status(.codex, installed: false)], errors: [:])
        #expect(rows.isEmpty)
    }

    @Test func cardsAreShownWhenNoRuntimeStatusIsKnownYet() {
        let rows = UsageRow.make(cards: [card("codex")], runtimes: [], errors: [:])
        #expect(rows.map(\.id) == ["codex"])
    }

    @Test func refreshErrorsAreAttachedToTheirRuntime() {
        let rows = UsageRow.make(
            cards: [card("claude")], runtimes: [status(.claude, installed: true), status(.codex, installed: true)],
            errors: ["codex": "no answer within 20 s", "claude": "rate limits read failed"])
        guard case .card(_, let claudeProblem) = rows[0], case .waiting(_, _, _, let codexProblem) = rows[1] else {
            Issue.record("unexpected rows \(rows)")
            return
        }
        #expect(claudeProblem?.raw == "rate limits read failed")
        #expect(codexProblem?.raw == "no answer within 20 s")
        #expect(codexProblem?.kind == .unknown)
    }

    @Test func rowsFollowTheFixedRuntimeOrder() {
        let rows = UsageRow.make(
            cards: [card("api"), card("grok")],
            runtimes: [status(.grok, installed: true), status(.codex, installed: true), status(.claude, installed: true)],
            errors: [:])
        #expect(rows.map(\.id) == ["claude", "codex", "grok", "api"])
    }

    @Test func signedOutRuntimeSaysSoEvenWithACachedCard() {
        let rows = UsageRow.make(cards: [card("codex")], runtimes: [signedOut(.codex)], errors: [:])
        #expect(rows.count == 1)
        guard case .waiting(_, _, let text, let problem) = rows[0] else {
            Issue.record("a signed-out runtime should not show its old card")
            return
        }
        #expect(text == L10n.AgentSheet.statusNeedsLogin)
        #expect(problem?.kind == .needsLogin)
        #expect(problem?.loginCommand == "codex login")
    }

    @Test func grokSaysItDoesNotReportItsLimits() {
        let rows = UsageRow.make(cards: [], runtimes: [status(.grok, installed: true)], errors: [:])
        guard case .waiting(_, _, let text, _) = rows[0] else {
            Issue.record("grok should have a waiting line")
            return
        }
        #expect(text == L10n.Usage.grokNoLimits)
    }

    @Test func rowsWithTheSameRankAreOrderedById() {
        let rows = UsageRow.make(
            cards: [card("zeta"), card("alpha")], runtimes: [], errors: [:])
        #expect(rows.map(\.id) == ["alpha", "zeta"])
    }
}
