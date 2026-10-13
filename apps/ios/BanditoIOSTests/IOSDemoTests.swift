import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The demo world the iPhone app shows with `-demo`: the core answers on iOS, with a team.
@MainActor
@Suite struct IOSDemoTests {
    @Test func theLaunchArgumentAsksForTheDemo() {
        #expect(IOSDemo.isRequested(in: ["Bandito", "-demo"]))
        #expect(!IOSDemo.isRequested(in: ["Bandito"]))
        #expect(!IOSDemo.isRequested(in: ["Bandito", "-demoo"]))
    }

    @Test func theDemoServerConnectsAndListsItsTeam() async {
        let server = await IOSDemo.start()
        #expect(server.state == .connected)
        #expect(server.agents.count == IOSDemo.team.count)
        #expect(Set(server.agents.map(\.name)) == Set(IOSDemo.team.map(\.name)))
        await server.disconnect()
    }

    @Test func everyAgentOfTheTeamHasARoleAndAStatus() async {
        let server = await IOSDemo.start()
        #expect(!server.sortedAgents.isEmpty)
        for agent in server.sortedAgents {
            #expect(!agent.role.isEmpty)
            #expect(agent.status != nil)
        }
        await server.disconnect()
    }
}
