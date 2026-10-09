import Foundation
import Testing

@testable import BanditoKit

@Suite struct RuntimeSwitchTests {
    func decode(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    @Test func switchWithResetTime() throws {
        let e = try decode(
            #"{"seq":21,"agent_id":"a","ts":1,"kind":"runtime.switched","payload":{"from":"claude","to":"codex","until":1790000000}}"#)
        #expect(e.body == .runtimeSwitched(from: "claude", to: "codex", until: 1_790_000_000))
    }

    @Test func switchWithoutResetTime() throws {
        let e = try decode(
            #"{"seq":22,"agent_id":"a","ts":1,"kind":"runtime.switched","payload":{"from":"codex","to":"claude"}}"#)
        #expect(e.body == .runtimeSwitched(from: "codex", to: "claude", until: nil))
    }

    @Test func threadKeepsTheSwitchAsAnItem() throws {
        var thread = AgentThread()
        let e = try decode(
            #"{"seq":21,"agent_id":"a","ts":1,"kind":"runtime.switched","payload":{"from":"claude","to":"codex"}}"#)
        thread.apply(e)
        guard case .runtimeSwitch(_, let from, let to, let until, _)? = thread.items.first else {
            Issue.record("expected a runtime switch item, got \(thread.items)")
            return
        }
        #expect(from == "claude")
        #expect(to == "codex")
        #expect(until == nil)
    }
}
