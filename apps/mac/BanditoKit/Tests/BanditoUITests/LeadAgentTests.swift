import Foundation
import Testing

@testable import BanditoUI

/// The main agent of a server: one per server, kept on this Mac, and always first in the team list.
@MainActor
@Suite struct LeadAgentTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "LeadAgentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func noMainAgentUntilOneIsSet() {
        let store = LeadAgentStore(defaults: freshDefaults())
        #expect(store.id(server: "s1") == nil)
    }

    @Test func settingAMainAgentIsPerServer() {
        let store = LeadAgentStore(defaults: freshDefaults())
        store.set("a1", server: "s1")
        #expect(store.id(server: "s1") == "a1")
        #expect(store.id(server: "s2") == nil)
    }

    @Test func anotherMainAgentReplacesTheOldOne() {
        let store = LeadAgentStore(defaults: freshDefaults())
        store.set("a1", server: "s1")
        store.set("a2", server: "s1")
        #expect(store.id(server: "s1") == "a2")
    }

    @Test func nilClearsTheMainAgent() {
        let store = LeadAgentStore(defaults: freshDefaults())
        store.set("a1", server: "s1")
        store.set(nil, server: "s1")
        #expect(store.id(server: "s1") == nil)
    }

    @Test func choiceSurvivesANewStoreOnTheSameDefaults() {
        let defaults = freshDefaults()
        LeadAgentStore(defaults: defaults).set("a1", server: "s1")
        #expect(LeadAgentStore(defaults: defaults).id(server: "s1") == "a1")
    }

    @Test func deletingTheMainAgentClearsTheChoice() {
        let store = LeadAgentStore(defaults: freshDefaults())
        store.set("a1", server: "s1")
        store.forget(agentID: "a2", server: "s1")
        #expect(store.id(server: "s1") == "a1", "another agent's deletion keeps the main one")
        store.forget(agentID: "a1", server: "s1")
        #expect(store.id(server: "s1") == nil)
    }

    @Test func choiceIsGoneForANewStoreAfterDeletion() {
        let defaults = freshDefaults()
        let store = LeadAgentStore(defaults: defaults)
        store.set("a1", server: "s1")
        store.forget(agentID: "a1", server: "s1")
        #expect(LeadAgentStore(defaults: defaults).id(server: "s1") == nil)
    }

    @Test func mainItemMovesToTheFront() {
        let ids = ["a", "b", "c"]
        #expect(LeadAgent.leadFirst(ids, id: { $0 }, lead: "c") == ["c", "a", "b"])
    }

    @Test func listWithMainFirstOrNoMainIsUnchanged() {
        let ids = ["a", "b", "c"]
        #expect(LeadAgent.leadFirst(ids, id: { $0 }, lead: "a") == ids)
        #expect(LeadAgent.leadFirst(ids, id: { $0 }, lead: nil) == ids)
        #expect(LeadAgent.leadFirst(ids, id: { $0 }, lead: "gone") == ids)
    }
}
