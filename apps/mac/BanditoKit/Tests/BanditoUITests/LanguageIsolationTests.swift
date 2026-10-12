import Testing

@testable import BanditoL10n

/// A test that switches the language for a moment switches it for its own task only. When the switch was a global,
/// suites that compare a text with an `L10n` string failed at random while another suite read German.
@Suite struct LanguageIsolationTests {
    @Test func aLanguageSwitchStaysInsideItsTask() async {
        let system = L10n.Team.Home.asleep
        let english = L10n.withLanguageForTests("en") { L10n.Team.Home.asleep }
        let german = L10n.withLanguageForTests("de") { L10n.Team.Home.asleep }
        #expect(english == "Asleep")
        #expect(german == "schläft")
        let wrong = await withTaskGroup(of: Int.self) { group in
            for lane in 0..<12 {
                group.addTask {
                    var wrong = 0
                    for _ in 0..<300 {
                        switch lane % 3 {
                        case 0: if L10n.withLanguageForTests("de", { L10n.Team.Home.asleep }) != german { wrong += 1 }
                        case 1: if L10n.withLanguageForTests("en", { L10n.Team.Home.asleep }) != english { wrong += 1 }
                        default: if L10n.Team.Home.asleep != system { wrong += 1 }
                        }
                        await Task.yield()
                    }
                    return wrong
                }
            }
            return await group.reduce(0, +)
        }
        #expect(wrong == 0)
    }

    @Test(.language("de")) func thePinnedLanguageReachesTheTest() {
        #expect(L10n.Team.Home.asleep == "schläft")
        #expect(L10n.locale.identifier == "de")
    }
}
