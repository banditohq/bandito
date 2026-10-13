import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@Suite struct FirstTaskSuggestionsTests {
    @Test func everyTeamGetsFourDistinctPromptsAndAnUnknownTeamTheGeneralFour() {
        for id in ["web-project", "server-duty", "morning-summary", "docs-upkeep", nil, "something-new"] {
            let prompts = FirstTaskSuggestions.prompts(forTeam: id)
            #expect(prompts.count == 4)
            #expect(Set(prompts).count == 4)
        }
    }

    @Test func theSuggestionsFitTheCrew() {
        #expect(FirstTaskSuggestions.prompts(forTeam: "server-duty").contains(.disk))
        #expect(FirstTaskSuggestions.prompts(forTeam: "web-project").contains(.tests))
        #expect(FirstTaskSuggestions.prompts(forTeam: "docs-upkeep").first == .docs)
        #expect(!FirstTaskSuggestions.prompts(forTeam: "web-project").contains(.disk))
    }

    @Test func everyPromptHasTextInEveryLanguageOfTheCatalog() {
        for prompt in FirstTaskSuggestions.Prompt.allCases {
            #expect(!prompt.text.isEmpty)
        }
    }
}

@Suite struct NightShiftTests {
    @Test func theCardSleepsUntilTheNextChangeNotPerFrame() {
        var t = 0.0
        var wakes = 0
        while t < NightShift.cycleSeconds - 0.001 {
            t += NightShift.secondsToNextChange(from: t)
            wakes += 1
            if wakes > 20 { break }
        }
        // Four events, the morning and the end of the cycle: six wakes, never one per tick.
        #expect(wakes == 6)
    }

    @Test func theStateFollowsTheCycle() {
        #expect(NightShift.state(at: 0) == (0, false))
        #expect(NightShift.state(at: NightShift.firstEventAt + 0.01).lit == 1)
        #expect(NightShift.state(at: NightShift.morningAt + 0.01) == (4, true))
        #expect(NightShift.state(at: NightShift.cycleSeconds + 0.1) == (0, false))
    }
}
