import Foundation
import Testing

@testable import BanditoKit

@Suite struct AgentFallbackTests {
    func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try RPCClient.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func agentDecodesFallbackFieldsAndDefaultsToNil() throws {
        let full = #"{"id":"a","name":"n","runtime":"claude","cwd":"/x","fallback_runtime":"codex","fallback_model":"gpt-5","active_runtime":"codex"}"#
        let a = try RPCClient.decoder.decode(Agent.self, from: Data(full.utf8))
        #expect(a.fallbackRuntime == .codex)
        #expect(a.fallbackModel == "gpt-5")
        #expect(a.activeRuntime == .codex)

        let old = #"{"id":"a","name":"n","runtime":"claude","cwd":"/x"}"#
        let b = try RPCClient.decoder.decode(Agent.self, from: Data(old.utf8))
        #expect(b.fallbackRuntime == nil)
        #expect(b.fallbackModel == nil)
        #expect(b.activeRuntime == nil)
    }

    @Test func newAgentSendsFallback() throws {
        var a = NewAgent(name: "Forge", runtime: .claude, cwd: "/w")
        a.fallbackRuntime = .grok
        a.fallbackModel = "grok-4"
        let body = try json(a)
        #expect(body["fallback_runtime"] as? String == "grok")
        #expect(body["fallback_model"] as? String == "grok-4")
    }

    @Test func newAgentWithoutFallbackOmitsIt() throws {
        let body = try json(NewAgent(name: "Forge", runtime: .claude, cwd: "/w"))
        #expect(body["fallback_runtime"] == nil)
    }

    @Test func patchOmitsUntouchedFields() throws {
        let body = try json(AgentPatch(model: .set("opus")))
        #expect(body["model"] as? String == "opus")
        #expect(body["runtime"] == nil)
        #expect(body["fallback_runtime"] == nil)
        #expect(body["fallback_model"] == nil)
    }

    @Test func patchSetsRuntimeAndFallback() throws {
        var patch = AgentPatch()
        patch.runtime = .codex
        patch.fallbackRuntime = .set(.claude)
        patch.fallbackModel = .set("sonnet")
        let body = try json(patch)
        #expect(body["runtime"] as? String == "codex")
        #expect(body["fallback_runtime"] as? String == "claude")
        #expect(body["fallback_model"] as? String == "sonnet")
    }

    @Test func patchClearsFallbackWithExplicitNull() throws {
        var patch = AgentPatch()
        patch.fallbackRuntime = .clear
        patch.fallbackModel = .clear
        let body = try json(patch)
        // The daemon reads `null` as "clear"; a missing key would leave the fallback as it is.
        #expect(body.keys.contains("fallback_runtime"))
        #expect(body["fallback_runtime"] is NSNull)
        #expect(body["fallback_model"] is NSNull)
    }

    /// The daemon answers with the agent object itself, plus a `warnings` list next to its fields.
    @Test func updateResponseIsTheAgentWithWarnings() throws {
        let raw = #"{"id":"a","name":"n","runtime":"codex","cwd":"/x","warnings":["effort reset to default"]}"#
        let update = try RPCClient.decoder.decode(AgentUpdate.self, from: Data(raw.utf8))
        #expect(update.agent.id == "a")
        #expect(update.agent.runtime == .codex)
        #expect(update.warnings == ["effort reset to default"])

        let plain = try RPCClient.decoder.decode(
            AgentUpdate.self, from: Data(#"{"id":"a","name":"n","runtime":"claude","cwd":"/x"}"#.utf8))
        #expect(plain.warnings.isEmpty)
    }
}
