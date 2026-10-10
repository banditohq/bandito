import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@Suite struct UsageSplitTests {
    private func card(_ runtime: String, plan: String? = nil, windows: [UsageWindowLine] = []) -> UsageCard {
        UsageCard(
            runtime: runtime, name: UsageCards.displayName(runtime), plan: plan, color: .peach, who: nil, windows: windows)
    }

    private let window = UsageWindowLine(id: "five_hour", label: "5h", remaining: 0.5, resetsAt: nil, note: nil)

    @Test func aSubscriptionWithoutWindowsStillGetsABlock() {
        let rows: [UsageRow] = [.card(card("claude", plan: "Max ×20"), problem: nil)]
        let split = UsageRow.split(rows, agentRuntimes: [])
        #expect(split.blocks.map(\.id) == ["claude"])
        #expect(split.others.isEmpty)
    }

    @Test func aRuntimeWithAgentsGetsABlockEvenWithoutData() {
        let rows: [UsageRow] = [.card(card("codex"), problem: nil)]
        let split = UsageRow.split(rows, agentRuntimes: ["codex"])
        #expect(split.blocks.map(\.id) == ["codex"])
        #expect(split.others.isEmpty)
    }

    @Test func aCardWithLimitDataGetsABlock() {
        let rows: [UsageRow] = [.card(card("codex", windows: [window]), problem: nil)]
        let split = UsageRow.split(rows, agentRuntimes: [])
        #expect(split.blocks.map(\.id) == ["codex"])
    }

    @Test func aRuntimeWithoutAgentsOrDataGoesOnTheSummaryLine() {
        let rows: [UsageRow] = [.card(card("codex"), problem: nil)]
        let split = UsageRow.split(rows, agentRuntimes: [])
        #expect(split.blocks.isEmpty)
        #expect(split.others == [UsageOtherRuntime(runtime: "codex", name: "Codex", reason: .noData)])
    }

    @Test func grokSaysItHasNoLimits() {
        let rows: [UsageRow] = [.waiting(runtime: "grok", name: "Grok", text: "", problem: nil)]
        let split = UsageRow.split(rows, agentRuntimes: [])
        #expect(split.others == [UsageOtherRuntime(runtime: "grok", name: "Grok", reason: .noLimits)])
    }

    @Test func aRuntimeThatNeedsLoginSaysSo() {
        let problem = UsageProblem.needsLogin(runtime: "codex", raw: "not logged in")
        let rows: [UsageRow] = [.waiting(runtime: "codex", name: "Codex", text: "", problem: problem)]
        let split = UsageRow.split(rows, agentRuntimes: [])
        #expect(split.blocks.isEmpty)
        #expect(split.others == [UsageOtherRuntime(runtime: "codex", name: "Codex", reason: .needsLogin)])
    }

    @Test func aSignedOutRuntimeWithAgentsKeepsItsBlock() {
        let problem = UsageProblem.needsLogin(runtime: "codex", raw: "not logged in")
        let rows: [UsageRow] = [.waiting(runtime: "codex", name: "Codex", text: "", problem: problem)]
        let split = UsageRow.split(rows, agentRuntimes: ["codex"])
        #expect(split.blocks.map(\.id) == ["codex"])
        #expect(split.others.isEmpty)
    }
}
