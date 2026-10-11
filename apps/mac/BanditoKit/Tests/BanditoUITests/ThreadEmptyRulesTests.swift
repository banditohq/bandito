import BanditoKit
import Testing

@testable import BanditoUI

/// The suggestions of an empty thread: the capabilities' ones first, in a fixed order, then the general ones, at most four.
@Suite struct ThreadEmptyRulesTests {
    private typealias Key = ThreadEmptyRules.Suggestion.Key

    private func agent(_ capabilities: [String]?) -> Agent {
        Agent(id: "a1", name: "Ada", runtime: .claude, cwd: "/work", capabilities: capabilities)
    }

    private func keys(_ capabilities: [String]?) -> [Key] {
        ThreadEmptyRules.suggestions(for: agent(capabilities)).map(\.key)
    }

    @Test func everyCapabilityGivesTheFourCapabilityLinesInOrder() {
        #expect(keys(["terminal", "files", "browser", "team", "screen"]) == [.listProject, .fixErrors, .news, .meetTeam])
    }

    @Test func aNilListMeansEveryCapability() {
        #expect(keys(nil) == [.listProject, .fixErrors, .news, .meetTeam])
    }

    @Test func terminalOrProjectFilesGiveTheProjectPairAndTheGeneralOnes() {
        let expected: [Key] = [.listProject, .fixErrors, .capabilities, .dayPlan]
        #expect(keys(["terminal"]) == expected)
        #expect(keys(["files"]) == expected)
    }

    @Test func browserOnlyGivesThreeSuggestions() {
        #expect(keys(["browser"]) == [.news, .capabilities, .dayPlan])
    }

    @Test func teamOnlyGivesTheCrewLineAndTheGeneralOnes() {
        #expect(keys(["team"]) == [.meetTeam, .capabilities, .dayPlan])
    }

    @Test func noCapabilityGivesOnlyTheTwoGeneralOnes() {
        #expect(keys([]) == [.capabilities, .dayPlan])
    }

    @Test func aCapabilityTheAppDoesNotKnowIsIgnored() {
        #expect(keys(["teleport"]) == [.capabilities, .dayPlan])
    }

    @Test func everySubsetOfCapabilitiesKeepsFourOrFewerWithoutRepeats() {
        let all = AgentCapability.allCases.map(\.rawValue)
        for mask in 0..<(1 << all.count) {
            let subset = all.indices.filter { mask & (1 << $0) != 0 }.map { all[$0] }
            let result = ThreadEmptyRules.suggestions(for: agent(subset))

            let hasProject = subset.contains("terminal") || subset.contains("files")
            let capabilityLines = (hasProject ? 2 : 0) + (subset.contains("browser") ? 1 : 0) + (subset.contains("team") ? 1 : 0)
            let expectedCount = min(ThreadEmptyRules.limit, capabilityLines + 2)

            #expect(result.count == expectedCount, "subset \(subset)")
            #expect(Set(result.map(\.key)).count == result.count, "repeat in \(subset)")
            #expect(result == ThreadEmptyRules.suggestions(for: agent(subset)), "unstable order for \(subset)")
            #expect(result.allSatisfy { !$0.text.isEmpty && !$0.symbol.isEmpty }, "empty line for \(subset)")
        }
    }

    @Test func theLimitIsFour() {
        #expect(ThreadEmptyRules.limit == 4)
        #expect(keys(nil).count == 4)
    }
}
