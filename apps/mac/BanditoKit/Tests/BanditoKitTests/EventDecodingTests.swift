import Foundation
import Testing

@testable import BanditoKit

@Suite struct EventDecodingTests {
    func decode(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    @Test func approvalRequested() throws {
        let e = try decode(
            #"{"seq":6,"agent_id":"a1","ts":1,"kind":"approval.requested","payload":{"approval_id":"ap1","call_id":"c1","tool":"Bash","title":"git push","command":"git push origin main","reason":"risky: git push*"}}"#
        )
        #expect(e.seq == 6)
        #expect(e.agentId == "a1")
        guard case .approvalRequested(let id, _, let tool, _, let command, let diff, let reason) = e.body else {
            Issue.record("wrong body \(e.body)")
            return
        }
        #expect(id == "ap1")
        #expect(tool == "Bash")
        #expect(command == "git push origin main")
        #expect(diff == nil)
        #expect(reason == "risky: git push*")
    }

    @Test func statusAndTurn() throws {
        let s = try decode(#"{"seq":3,"agent_id":"a","ts":1,"kind":"agent.status","payload":{"status":"needs_you"}}"#)
        #expect(s.body == .agentStatus(status: .needsYou, detail: nil))
        let t = try decode(
            #"{"seq":12,"agent_id":"a","ts":1,"kind":"turn.completed","payload":{"turn_id":"t","status":"ok","usage":{"input_tokens":5,"output_tokens":2},"cost_usd":0.01}}"#
        )
        #expect(t.body == .turnCompleted(turnId: "t", status: .ok, usage: Usage(inputTokens: 5, outputTokens: 2), costUsd: 0.01))
    }

    @Test func toolCallKeepsInput() throws {
        let e = try decode(
            #"{"seq":4,"agent_id":"a","ts":1,"kind":"tool.call","payload":{"call_id":"c","tool":"Bash","title":"ls","input":{"command":"ls","n":2}}}"#
        )
        guard case .toolCall(_, _, _, let input) = e.body else { Issue.record("wrong body"); return }
        #expect(input["command"]?.string == "ls")
    }

    @Test func unknownKindIsKept() throws {
        let e = try decode(#"{"seq":9,"agent_id":"a","ts":1,"kind":"future.thing","payload":{"x":1}}"#)
        #expect(e.body == .unknown(kind: "future.thing"))
    }

    @Test func deltaHasNoSeq() throws {
        let e = try decode(#"{"seq":0,"agent_id":"a","ts":7,"kind":"message.delta","payload":{"text":"Hel"}}"#)
        #expect(e.body == .messageDelta(text: "Hel"))
        #expect(e.id == "da-7")
    }

    @Test func agentDecodes() throws {
        let a = try RPCClient.decoder.decode(
            Agent.self,
            from: Data(
                #"{"id":"a","name":"Forge","role":"builder","runtime":"claude","model":null,"cwd":"/w","approval_mode":"risky","system_prompt":null,"runtime_session_id":null,"created_at":1,"updated_at":2}"#
                    .utf8))
        #expect(a.runtime == .claude)
        #expect(a.approvalMode == .risky)
    }
}
