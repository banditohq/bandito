import Foundation
import Testing

@testable import BanditoKit

@Suite struct AgentPauseTests {
    func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try RPCClient.encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func agentDecodesPausedAndDefaultsToRunning() throws {
        let paused = #"{"id":"a","name":"n","runtime":"claude","cwd":"/x","paused":true}"#
        #expect(try RPCClient.decoder.decode(Agent.self, from: Data(paused.utf8)).paused)

        let old = #"{"id":"a","name":"n","runtime":"claude","cwd":"/x"}"#
        #expect(try !RPCClient.decoder.decode(Agent.self, from: Data(old.utf8)).paused)
    }

    @Test func patchSendsPausedOnlyWhenSet() throws {
        let pause = try json(AgentPatch(paused: true))
        #expect(pause["paused"] as? Bool == true)
        #expect(pause["model"] == nil)

        let untouched = try json(AgentPatch(model: .set("opus")))
        #expect(untouched["paused"] == nil)
    }
}
