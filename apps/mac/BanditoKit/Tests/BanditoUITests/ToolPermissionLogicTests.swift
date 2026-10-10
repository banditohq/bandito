import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The "Tools" section of a service: what a tool does, and what the daemon will do with it.
@Suite struct ToolPermissionLogicTests {
    private let read = IntegrationTool(name: "list", readOnly: true)
    private let write = IntegrationTool(name: "create")
    private let drop = IntegrationTool(name: "drop", destructive: true)

    private func agent(_ id: String, _ runtime: String) throws -> Agent {
        try RPCClient.decoder.decode(
            Agent.self, from: Data(#"{"id":"\#(id)","name":"N\#(id)","runtime":"\#(runtime)","cwd":"/x"}"#.utf8))
    }

    @Test func aToolReadsChangesOrDeletes() {
        #expect(ToolPermissionLogic.kind(of: read) == .reads)
        #expect(ToolPermissionLogic.kind(of: write) == .changes)
        #expect(ToolPermissionLogic.kind(of: drop) == .deletes)
        // Marked destructive wins, even next to a read-only mark; a tool with no mark at all changes things.
        #expect(ToolPermissionLogic.kind(of: IntegrationTool(name: "x", readOnly: true, destructive: true)) == .deletes)
        #expect(ToolPermissionLogic.kind(of: IntegrationTool(name: "x")) == .changes)
    }

    @Test func theModeSaysWhatEachKindDoes() {
        for tool in [read, write, drop] {
            #expect(ToolPermissionLogic.modeWord(.all, for: tool) == .allow)
        }
        #expect(ToolPermissionLogic.modeWord(.readOnly, for: read) == .allow)
        #expect(ToolPermissionLogic.modeWord(.readOnly, for: write) == .deny)
        #expect(ToolPermissionLogic.modeWord(.readOnly, for: drop) == .deny)
        #expect(ToolPermissionLogic.modeWord(.confirmWrites, for: read) == .allow)
        #expect(ToolPermissionLogic.modeWord(.confirmWrites, for: write) == .ask)
        #expect(ToolPermissionLogic.modeWord(.confirmWrites, for: drop) == .ask)
    }

    @Test func theOwnersWordWinsOverTheMode() {
        let words: [String: ToolWord] = ["create": .allow, "list": .deny]
        #expect(ToolPermissionLogic.effectiveWord(of: write, mode: .readOnly, overrides: words) == .allow)
        #expect(ToolPermissionLogic.effectiveWord(of: read, mode: .all, overrides: words) == .deny)
        #expect(ToolPermissionLogic.effectiveWord(of: drop, mode: .confirmWrites, overrides: words) == .ask)
    }

    @Test func aWordThatIsWhatTheModeDoesAnywayIsNotKept() {
        // Picking Ask for a write in confirm mode is the mode's own answer: no word is stored.
        let none = ToolPermissionLogic.overrides(setting: .ask, for: write, mode: .confirmWrites, current: [:])
        #expect(none.isEmpty)
        let denied = ToolPermissionLogic.overrides(setting: .deny, for: write, mode: .confirmWrites, current: [:])
        #expect(denied == ["create": .deny])
        // Going back to the mode's answer drops the word, and leaves the others.
        let back = ToolPermissionLogic.overrides(
            setting: .ask, for: write, mode: .confirmWrites, current: ["create": .deny, "other": .allow])
        #expect(back == ["other": .allow])
        // Words for tools that are not in the list stay.
        let kept = ToolPermissionLogic.overrides(setting: .deny, for: read, mode: .all, current: ["gone": .deny])
        #expect(kept == ["gone": .deny, "list": .deny])
    }

    @Test func theListHasDeletesFirstThenChangesThenReads() {
        let tools = [read, IntegrationTool(name: "b_read", readOnly: true), write, drop, IntegrationTool(name: "a_write")]
        let order = ToolPermissionLogic.sorted(tools).map(\.name)
        #expect(order == ["drop", "a_write", "create", "b_read", "list"])
        let counts = ToolPermissionLogic.counts(tools)
        #expect(counts.reads == 2 && counts.changes == 2 && counts.deletes == 1)
    }

    @Test func aServiceNeverCheckedHasNoToolsToShow() {
        #expect(ToolPermissionLogic.content([]) == .notChecked)
        #expect(ToolPermissionLogic.content([write, read]) == .tools([write, read]))
    }

    @Test func codexAndGrokAgentsAreTheOnesTheModesDoNotReach() throws {
        let agents = [try agent("a", "claude"), try agent("b", "codex"), try agent("c", "grok")]
        #expect(ToolPermissionLogic.unreachedAgents(agents) == ["Nb", "Nc"])
        #expect(ToolPermissionLogic.unreachedAgents([try agent("a", "claude")]).isEmpty)
    }

    @Test func theApprovalReasonsOfAServiceHaveWords() {
        let confirm = ApprovalReason.text("service: confirm changes")
        let tool = ApprovalReason.text("service: confirm tool")
        #expect(confirm != "service: confirm changes" && tool != "service: confirm tool")
        #expect(confirm != tool)
    }
}
