import Testing

@testable import BanditoUI

@Suite struct TerminalDisplayTests {
    @Test func nobodyOwnsTheDisplayAtFirst() {
        let owner = TerminalDisplayOwner()
        #expect(owner.place == nil)
        #expect(!owner.isOwner(TerminalDisplayOwner.terminals))
    }

    @Test func lastClaimWins() {
        var owner = TerminalDisplayOwner()
        let pane = TerminalDisplayOwner.workbench(agentID: "forge", pane: 0)
        owner.claim(TerminalDisplayOwner.terminals)
        owner.claim(pane)
        #expect(owner.isOwner(pane))
        #expect(!owner.isOwner(TerminalDisplayOwner.terminals))
    }

    @Test func releaseClearsOnlyWhenReleasingPlaceOwns() {
        var owner = TerminalDisplayOwner()
        let pane = TerminalDisplayOwner.workbench(agentID: "forge", pane: 0)
        let other = TerminalDisplayOwner.workbench(agentID: "forge", pane: 1)
        owner.claim(pane)
        owner.release(other)
        #expect(owner.isOwner(pane))
        owner.release(pane)
        #expect(owner.place == nil)
    }

    @Test func panePlacesAreDistinctPerAgentAndPane() {
        #expect(TerminalDisplayOwner.workbench(agentID: "forge", pane: 0) == "workbench:forge:0")
        #expect(TerminalDisplayOwner.workbench(agentID: "forge", pane: 1) != TerminalDisplayOwner.workbench(agentID: "scout", pane: 1))
    }
}
