import Foundation
import Testing

@testable import BanditoKit

@Suite struct LastOpenedAgentTests {
    @Test func selectedAgentOnThisServerWins() {
        let id = LastOpenedAgent.resolve(selected: "b", remembered: "c", agentIDs: ["a", "b", "c"])
        #expect(id == "b")
    }

    @Test func selectedAgentFromAnotherServerIsIgnored() {
        // The selection is kept across servers; an id this server does not have must not be shown.
        let id = LastOpenedAgent.resolve(selected: "gone", remembered: "c", agentIDs: ["a", "b", "c"])
        #expect(id == "c")
    }

    @Test func rememberedAgentIsUsedWhenNothingIsSelected() {
        #expect(LastOpenedAgent.resolve(selected: nil, remembered: "b", agentIDs: ["a", "b"]) == "b")
    }

    @Test func firstAgentIsUsedWhenNothingIsRemembered() {
        #expect(LastOpenedAgent.resolve(selected: nil, remembered: "gone", agentIDs: ["a", "b"]) == "a")
        #expect(LastOpenedAgent.resolve(selected: nil, remembered: nil, agentIDs: ["a", "b"]) == "a")
    }

    @Test func noAgentsResolvesToNothing() {
        #expect(LastOpenedAgent.resolve(selected: "a", remembered: "a", agentIDs: []) == nil)
    }

    @Test func rememberedAgentIsKeptPerServer() throws {
        let suite = "LastOpenedAgentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        LastOpenedAgent.save("agent-1", serverID: "server-A", defaults: defaults)

        #expect(LastOpenedAgent.load(serverID: "server-A", defaults: defaults) == "agent-1")
        #expect(LastOpenedAgent.load(serverID: "server-B", defaults: defaults) == nil)
    }
}
