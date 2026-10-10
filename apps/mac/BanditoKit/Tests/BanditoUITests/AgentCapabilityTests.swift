import Testing

@testable import BanditoUI

/// Logic behind the "What it may do" chips: a click flips one capability and leaves the others alone.
@Suite struct AgentCapabilityTests {
    @Test func everyCapabilityIsOnByDefault() {
        #expect(AgentCapability.allOn == Set(AgentCapability.allCases))
        #expect(AgentCapability.allCases.count == 5)
    }

    @Test func clickingAnOnChipTurnsItOff() {
        let next = AgentCapability.toggled(AgentCapability.allOn, .browser)
        #expect(!next.contains(.browser))
        #expect(next.count == 4)
    }

    @Test func clickingAnOffChipTurnsItOn() {
        let off: Set<AgentCapability> = [.terminal]
        #expect(AgentCapability.toggled(off, .files) == [.terminal, .files])
    }

    @Test func twoClicksGiveBackTheSameSet() {
        let start: Set<AgentCapability> = [.team, .screen]
        for capability in AgentCapability.allCases {
            #expect(AgentCapability.toggled(AgentCapability.toggled(start, capability), capability) == start)
        }
    }

    @Test func wireListRoundTripsAndNilMeansAll() {
        #expect(AgentCapability.set(from: nil) == AgentCapability.allOn)
        #expect(AgentCapability.set(from: ["terminal", "team"]) == [.terminal, .team])
        #expect(AgentCapability.set(from: ["team", "from-the-future"]) == [.team])
        #expect(AgentCapability.wire([.screen, .terminal]) == ["terminal", "screen"])
        #expect(AgentCapability.set(from: AgentCapability.wire(AgentCapability.allOn)) == AgentCapability.allOn)
    }

    @Test func everyCapabilityHasATitle() {
        for capability in AgentCapability.allCases {
            #expect(!capability.title.isEmpty)
        }
    }
}
