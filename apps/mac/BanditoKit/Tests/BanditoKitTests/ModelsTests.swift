import Foundation
import Testing

@testable import BanditoKit

@Suite struct ModelsTests {
    func decodeAgent(_ json: String) throws -> Agent {
        try RPCClient.decoder.decode(Agent.self, from: Data(json.utf8))
    }

    func decodeEvent(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    @Test func agentWithoutNewFieldsGetsDefaults() throws {
        let a = try decodeAgent(
            #"{"id":"a","name":"Forge","role":"builder","runtime":"claude","cwd":"/w","approval_mode":"risky","created_at":1,"updated_at":2}"#)
        #expect(a.memoryMode == .smart)
        #expect(a.contextTokens == 0)
        #expect(a.chapter == 1)
        #expect(a.effort == nil)
        #expect(a.contextBudget == nil)
        #expect(a.homeDir == nil)
        #expect(a.lastTurnAt == nil)
    }

    @Test func agentWithNewFieldsDecodes() throws {
        let a = try decodeAgent(
            #"{"id":"a","name":"Forge","runtime":"codex","cwd":"/w","created_at":1,"updated_at":2,"effort":"high","memory_mode":"daily","context_budget":90000,"home_dir":"/h/forge","context_tokens":1200,"chapter":3,"last_turn_at":99}"#)
        #expect(a.effort == .high)
        #expect(a.memoryMode == .daily)
        #expect(a.contextBudget == 90_000)
        #expect(a.homeDir == "/h/forge")
        #expect(a.contextTokens == 1200)
        #expect(a.chapter == 3)
        #expect(a.lastTurnAt == 99)
    }

    @Test func unknownAgentValuesFallBackInsteadOfFailing() throws {
        let a = try decodeAgent(
            #"{"id":"a","name":"Forge","runtime":"gemini","cwd":"/w","approval_mode":"ask","effort":"turbo","memory_mode":"forever"}"#)
        #expect(a.runtime == .api)
        #expect(a.approvalMode == .always)
        #expect(a.effort == .medium)
        #expect(a.memoryMode == .smart)
    }

    @Test func unknownStatusDoesNotBreakTheEvent() throws {
        let e = try decodeEvent(
            #"{"seq":5,"agent_id":"a","ts":1,"kind":"agent.status","payload":{"status":"hibernating"}}"#)
        #expect(e.body == .agentStatus(status: .idle, detail: nil))
    }

    @Test func unknownTurnAndDecisionValuesFallBack() throws {
        let t = try decodeEvent(
            #"{"seq":6,"agent_id":"a","ts":1,"kind":"turn.completed","payload":{"turn_id":"t","status":"paused"}}"#)
        #expect(t.body == .turnCompleted(turnId: "t", status: .error, usage: nil, costUsd: nil))
        let r = try decodeEvent(
            #"{"seq":7,"agent_id":"a","ts":1,"kind":"approval.resolved","payload":{"approval_id":"ap","decision":"maybe","by":"robot","remember":false}}"#)
        #expect(r.body == .approvalResolved(approvalId: "ap", decision: .deny, by: .policy, remember: false))
    }

    @Test func unknownMessageSourceFallsBackToUser() throws {
        let e = try decodeEvent(
            #"{"seq":8,"agent_id":"a","ts":1,"kind":"message.user","payload":{"text":"hi","source":"webhook"}}"#)
        #expect(e.body == .messageUser(text: "hi", source: .user, fromAgent: nil))
    }

    @Test func systemMessageAndSessionRotatedDecode() throws {
        let s = try decodeEvent(
            #"{"seq":9,"agent_id":"a","ts":1,"kind":"message.user","payload":{"text":"save","source":"system"}}"#)
        #expect(s.body == .messageUser(text: "save", source: .system, fromAgent: nil))
        let r = try decodeEvent(
            #"{"seq":10,"agent_id":"a","ts":1,"kind":"session.rotated","payload":{"chapter":2,"reason":"smart","context_tokens":1234}}"#)
        #expect(r.body == .sessionRotated(chapter: 2, reason: "smart", contextTokens: 1234))
    }

    @Test func usageEntryWithoutTimestampGetsNow() throws {
        let before = Int64(Date().timeIntervalSince1970 * 1000) - 1_000
        let entry = try RPCClient.decoder.decode(
            UsageEntry.self,
            from: Data(#"{"runtime":"codex","windows":[{"name":"week","utilization":0.5,"resets_at":null}]}"#.utf8))
        #expect(entry.runtime == "codex")
        #expect(entry.windows.first?.utilization == 0.5)
        #expect(entry.updatedAt >= before)
    }

    @Test func usageEntryDecodesPlan() throws {
        let withPlan = try RPCClient.decoder.decode(
            UsageEntry.self,
            from: Data(
                #"{"runtime":"claude","windows":[],"updated_at":5,"plan":{"id":"max_20x","label":"Max ×20"}}"#.utf8))
        #expect(withPlan.plan == Plan(id: "max_20x", label: "Max ×20"))
        let withoutPlan = try RPCClient.decoder.decode(
            UsageEntry.self, from: Data(#"{"runtime":"codex","windows":[],"updated_at":5}"#.utf8))
        #expect(withoutPlan.plan == nil)
    }

    @Test func serverConfigDoesNotEncodeOrPrintTheToken() throws {
        let config = ServerConfig(name: "vps", endpoint: .local(socketPath: "/tmp/x.sock"), token: "very-secret")
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!json.contains("very-secret"))
        #expect(!json.contains("token"))
        #expect(!config.description.contains("very-secret"))
        #expect(config.description == "ServerConfig(name: vps, connection: local)")
    }
}
