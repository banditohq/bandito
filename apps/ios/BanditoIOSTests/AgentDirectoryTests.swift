import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The agents the intents can name: the directory, the entities, the search by name and the ids the links carry.
@Suite struct AgentDirectoryTests {
    private let server = "6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B"

    private var entities: [AgentEntity] {
        AgentDirectory.entities([
            WidgetSnapshot.Listing(server: server, id: "forge", name: "Forge", role: "Coder"),
            WidgetSnapshot.Listing(server: server, id: "watch", name: "Watch", role: "Ops"),
            WidgetSnapshot.Listing(server: server, id: "café", name: "Café Bot", role: ""),
        ])
    }

    @Test func anEntityIsServerAndAgentAndItsLinkId() {
        let entity = entities[0]
        #expect(entity.id == "\(server)/forge")
        #expect(entity.serverID == server && entity.agentID == "forge")
        #expect(entity.name == "Forge" && entity.role == "Coder")
    }

    @Test func aSearchByNameIgnoresCaseAndAccents() {
        #expect(AgentDirectory.matching(entities, text: "forge").map(\.agentID) == ["forge"])
        #expect(AgentDirectory.matching(entities, text: "WAT").map(\.agentID) == ["watch"])
        #expect(AgentDirectory.matching(entities, text: "cafe").map(\.agentID) == ["café"])
        #expect(AgentDirectory.matching(entities, text: "  Bot ").map(\.agentID) == ["café"])
    }

    @Test func aSearchFindsNothingForAnUnknownName() {
        #expect(AgentDirectory.matching(entities, text: "Nobody").isEmpty)
    }

    @Test func anEmptySearchFindsAllAgents() {
        #expect(AgentDirectory.matching(entities, text: "").count == 3)
        #expect(AgentDirectory.matching(entities, text: "   ").count == 3)
        #expect(AgentDirectory.matching([], text: "").isEmpty)
    }

    @Test func identifiersGiveTheirAgentsInTheirOrderAndUnknownOnesAreLeftOut() {
        let picked = AgentDirectory.entities(ids: ["\(server)/watch", "nope/none", "\(server)/forge"], in: entities)
        #expect(picked.map(\.agentID) == ["watch", "forge"])
        #expect(AgentDirectory.entities(ids: [], in: entities).isEmpty)
    }

    @Test func aDirectoryWithTheSameAgentTwiceKeepsOneEntity() {
        let twice = AgentDirectory.entities(ids: ["\(server)/forge"], in: entities + entities)
        #expect(twice.count == 1)
    }
}
