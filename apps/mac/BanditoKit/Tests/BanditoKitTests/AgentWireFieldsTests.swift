import Foundation
import Testing

@testable import BanditoKit

/// The avatar and capabilities fields: read when the daemon sends them, written only when set.
@Suite struct AgentWireFieldsTests {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try RPCClient.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func agentReadsAvatarAndCapabilities() throws {
        let raw = #"{"id":"a","name":"n","runtime":"claude","cwd":"/x","avatar":{"color":"sky","face":"dots"},"capabilities":["terminal","team"]}"#
        let agent = try RPCClient.decoder.decode(Agent.self, from: Data(raw.utf8))
        #expect(agent.avatar == AvatarSpec(color: "sky", face: "dots"))
        #expect(agent.capabilities == ["terminal", "team"])
    }

    @Test func agentFromOldDaemonHasNoAvatarOrCapabilities() throws {
        let raw = #"{"id":"a","name":"n","runtime":"claude","cwd":"/x"}"#
        let agent = try RPCClient.decoder.decode(Agent.self, from: Data(raw.utf8))
        #expect(agent.avatar == nil)
        #expect(agent.capabilities == nil)
    }

    @Test func patchSendsAvatarAndCapabilitiesOnlyWhenSet() throws {
        let untouched = try json(AgentPatch(paused: true))
        #expect(untouched["avatar"] == nil)
        #expect(untouched["capabilities"] == nil)

        let set = try json(AgentPatch(avatar: AvatarSpec(color: "rose", face: "carets"), capabilities: ["files"]))
        #expect((set["avatar"] as? [String: String]) == ["color": "rose", "face": "carets"])
        #expect((set["capabilities"] as? [String]) == ["files"])
    }

    @Test func createSendsAvatarAndCapabilitiesOnlyWhenSet() throws {
        let plain = try json(NewAgent(name: "n", runtime: .claude, cwd: "/x"))
        #expect(plain["avatar"] == nil)
        #expect(plain["capabilities"] == nil)

        let full = try json(NewAgent(
            name: "n", runtime: .claude, cwd: "/x",
            avatar: AvatarSpec(color: "peach", face: "auto"), capabilities: ["screen"]))
        #expect((full["avatar"] as? [String: String]) == ["color": "peach", "face": "auto"])
        #expect((full["capabilities"] as? [String]) == ["screen"])
    }
}
