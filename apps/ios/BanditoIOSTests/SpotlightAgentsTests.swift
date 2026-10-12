import CoreSpotlight
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The Spotlight items of the agents: what they say, what changed since the last index, and where a tap goes.
@Suite struct SpotlightAgentsTests {
    private let server = "6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B"

    private func listing(_ id: String, name: String? = nil, role: String = "Coder") -> WidgetSnapshot.Listing {
        WidgetSnapshot.Listing(server: server, id: id, name: name ?? id.capitalized, role: role)
    }

    @Test func anItemIsTheAgentByItsNameAndRoleInTheAgentsDomain() {
        let item = SpotlightAgents.item(for: listing("forge"))
        #expect(item.uniqueIdentifier == "\(server)/forge")
        #expect(item.domainIdentifier == "agents")
        #expect(item.attributeSet.title == "Forge")
        #expect(item.attributeSet.contentDescription == "Coder")
        #expect(item.attributeSet.keywords?.contains("Forge") == true)
    }

    @Test func anAgentWithoutARoleHasNoDescription() {
        let item = SpotlightAgents.item(for: listing("forge", role: ""))
        #expect(item.attributeSet.contentDescription == nil)
    }

    @Test func aFirstSyncIndexesEveryAgent() {
        let directory = [listing("forge"), listing("watch")]
        let plan = SpotlightAgents.plan(indexed: [:], directory: directory)
        #expect(plan.update == directory)
        #expect(plan.remove.isEmpty)
    }

    @Test func anUnchangedDirectoryIndexesNothing() {
        let directory = [listing("forge"), listing("watch")]
        let indexed = Dictionary(uniqueKeysWithValues: directory.map {
            (SpotlightAgents.identifier(for: $0), SpotlightAgents.signature(of: $0))
        })
        #expect(SpotlightAgents.plan(indexed: indexed, directory: directory).isEmpty)
    }

    @Test func aRenamedOrRerolledAgentIsReindexedAndTheOthersAreNot() {
        let before = [listing("forge"), listing("watch")]
        let indexed = Dictionary(uniqueKeysWithValues: before.map {
            (SpotlightAgents.identifier(for: $0), SpotlightAgents.signature(of: $0))
        })
        let after = [listing("forge", name: "Forge 2"), listing("watch", role: "Ops")]
        let plan = SpotlightAgents.plan(indexed: indexed, directory: after)
        #expect(plan.update.map(\.id) == ["forge", "watch"])
        let onlyRole = SpotlightAgents.plan(indexed: indexed, directory: [listing("forge"), listing("watch", role: "Ops")])
        #expect(onlyRole.update.map(\.id) == ["watch"])
    }

    @Test func anAgentGoneFromTheDirectoryIsRemovedFromTheIndex() {
        let indexed = [
            "\(server)/forge": SpotlightAgents.signature(of: listing("forge")),
            "\(server)/watch": SpotlightAgents.signature(of: listing("watch")),
        ]
        let plan = SpotlightAgents.plan(indexed: indexed, directory: [listing("forge")])
        #expect(plan.update.isEmpty)
        #expect(plan.remove == ["\(server)/watch"])
    }

    @Test func aDuplicatedAgentIsIndexedOnce() {
        let plan = SpotlightAgents.plan(indexed: [:], directory: [listing("forge"), listing("forge")])
        #expect(plan.update.count == 1)
    }

    @Test func anItemIdOpensTheAgentsLink() {
        #expect(SpotlightAgents.link(forIdentifier: "\(server)/forge") == .agent(server: server, id: "forge"))
        #expect(SpotlightAgents.link(forIdentifier: "forge") == nil)
        #expect(SpotlightAgents.link(forIdentifier: "/forge") == nil)
        #expect(SpotlightAgents.link(forIdentifier: "\(server)/") == nil)
        #expect(SpotlightAgents.link(forIdentifier: "\(server)/a/b") == nil)
    }

    @Test func aTapOnASpotlightResultOpensItsAgent() {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: "\(server)/forge"]
        #expect(SpotlightAgents.link(from: activity) == .agent(server: server, id: "forge"))
    }

    @Test func otherActivitiesAreNotSpotlightTaps() {
        let other = NSUserActivity(activityType: "dev.bandito.ios.something")
        other.userInfo = [CSSearchableItemActivityIdentifier: "\(server)/forge"]
        #expect(SpotlightAgents.link(from: other) == nil)
        let empty = NSUserActivity(activityType: CSSearchableItemActionType)
        #expect(SpotlightAgents.link(from: empty) == nil)
    }
}
