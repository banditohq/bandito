import BanditoKit
import Testing

@testable import BanditoUI

/// Which templates the team home's template section shows: the built-in ones, or the bots of the server's catalog.
@Suite struct TeamHomeSourceTests {
    private func bot(_ id: String) -> BotTemplate {
        BotTemplate(id: id, nameEn: id.capitalized, nameRu: id.capitalized)
    }

    @Test func withoutTheFeatureTheBuiltInTemplatesShow() {
        let source = TeamHomeLogic.templateSource(supportsBots: false, bots: [bot("a"), bot("b")])
        #expect(source == .builtIn)
    }

    @Test func withTheFeatureTheFirstFiveBotsShowInTheServersOrder() {
        let all = (1...7).map { bot("bot\($0)") }
        let source = TeamHomeLogic.templateSource(supportsBots: true, bots: all)
        #expect(source == .bots(Array(all.prefix(5))))
        #expect(TeamHomeLogic.botLimit == 5)
    }

    @Test func fewerBotsThanTheLimitAllShow() {
        let two = [bot("x"), bot("y")]
        #expect(TeamHomeLogic.templateSource(supportsBots: true, bots: two) == .bots(two))
    }

    @Test func withTheFeatureButNoBotsYetTheListIsEmpty() {
        #expect(TeamHomeLogic.templateSource(supportsBots: true, bots: []) == .bots([]))
    }
}
