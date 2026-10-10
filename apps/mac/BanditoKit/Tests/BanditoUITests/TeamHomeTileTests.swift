import BanditoKit
import BanditoL10n
import Testing

@testable import BanditoUI

/// Pure logic of the team home tiles: the template tiles and the status word of a recent agent.
@Suite struct TeamHomeTileTests {
    @Test func everyTemplateHasItsOwnTileColor() {
        let colors = AgentTemplate.allCases.map { TeamHomeLogic.tile(for: $0).color.rawValue }
        #expect(Set(colors).count == AgentTemplate.allCases.count)
    }

    @Test func templatesHaveTheirSymbols() {
        #expect(TeamHomeLogic.tile(for: .builder).symbol == "hammer")
        #expect(TeamHomeLogic.tile(for: .reviewer).symbol == "checkmark.seal")
        #expect(TeamHomeLogic.tile(for: .oncall).symbol == "bell")
        #expect(TeamHomeLogic.tile(for: .assistant).symbol == "calendar")
        #expect(TeamHomeLogic.tile(for: .researcher).symbol == "magnifyingglass")
        #expect(TeamHomeLogic.tile(for: .scratch).symbol == "plus")
    }

    @Test func idleAndOfflineAgentsAreAsleep() {
        #expect(TeamHomeLogic.statusWord(.idle) == L10n.Team.Home.asleep)
        #expect(TeamHomeLogic.statusWord(.offline) == L10n.Team.Home.asleep)
    }

    @Test func busyStatesHaveTheirOwnWords() {
        #expect(TeamHomeLogic.statusWord(.working) == L10n.Status.working)
        #expect(TeamHomeLogic.statusWord(.needsYou) == L10n.Status.needsYou)
        #expect(TeamHomeLogic.statusWord(.error) == L10n.Status.error)
    }
}
