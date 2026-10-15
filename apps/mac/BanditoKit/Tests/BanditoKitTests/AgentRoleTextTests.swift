@testable import BanditoKit
import Testing

/// A role that only looks empty (spaces, zero-width characters, filler) is no role; a real one keeps its words.
@Suite struct AgentRoleTextTests {
    @Test func aPlainRoleIsShownAsItIs() {
        #expect(AgentRoleText.visible("helper") == "helper")
        #expect(AgentRoleText.visible("  QA lead ") == "QA lead")
    }

    @Test func blankRolesAreNoRole() {
        #expect(AgentRoleText.visible("") == nil)
        #expect(AgentRoleText.visible("   \n\t ") == nil)
        #expect(AgentRoleText.visible("\u{200B}\u{200C}\u{FEFF}") == nil)
        #expect(AgentRoleText.visible("\u{2800}\u{3164} ") == nil)
        #expect(AgentRoleText.visible("\u{202E}\u{200F}") == nil)
    }

    @Test func invisibleCharactersAroundAWordAreDropped() {
        #expect(AgentRoleText.visible("\u{200B}helper\u{FEFF}") == "helper")
        #expect(AgentRoleText.visible("de\u{200D}v") == "dev")
    }

    @Test func controlCharactersBecomeSpaces() {
        #expect(AgentRoleText.visible("first\nsecond") == "first second")
        #expect(AgentRoleText.visible("\u{0007}ops") == "ops")
    }
}
