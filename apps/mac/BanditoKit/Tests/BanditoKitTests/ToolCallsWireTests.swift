import Foundation
import Testing

@testable import BanditoKit

/// The call journal and `integrations.call_tool`.
@MainActor
@Suite struct ToolCallsWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    @Test func aRowOfTheJournalDecodes() throws {
        let rows = try decode(
            [ToolCallRecord].self,
            #"[{"id":7,"at_ms":1000,"agent_id":"a1","integration":"linear","tool":"save_issue","duration_ms":340,"ok":false,"error":"rate limited","decision":"asked"},{"id":6,"at_ms":900,"agent_id":"a1","integration":"linear","tool":"list","duration_ms":null,"ok":null,"error":null,"decision":null}]"#)
        #expect(rows[0].id == 7 && rows[0].atMs == 1000)
        #expect(rows[0].integration == "linear" && rows[0].tool == "save_issue")
        #expect(rows[0].durationMs == 340 && rows[0].ok == false && rows[0].error == "rate limited")
        #expect(rows[0].decision == .asked)
        #expect(rows[1].ok == nil && rows[1].durationMs == nil && rows[1].decision == nil)
        let unknown = try decode([ToolCallRecord].self, #"[{"id":1,"decision":"maybe"}]"#)
        #expect(unknown[0].decision == .asked)
    }

    @Test func theStatsDecodeWithDigitsInTheirNames() throws {
        let stats = try decode(
            [IntegrationCallStats].self,
            #"[{"integration":"linear","calls_24h":12,"errors_24h":1,"calls_7d":40,"last_at":5000}]"#)
        #expect(stats == [IntegrationCallStats(integration: "linear", calls24h: 12, errors24h: 1, calls7d: 40, lastAt: 5000)])
    }

    @Test func theAnswerOfATryDecodes() throws {
        let answer = try decode(
            ToolCallResult.self,
            ##"{"is_error":false,"content":[{"type":"text","text":"hi"},{"type":"image"}],"structured":{"a":[1,2]}}"##)
        #expect(!answer.isError)
        #expect(answer.content == [ToolContentPart(type: "text", text: "hi"), ToolContentPart(type: "image")])
        #expect(answer.structured?["a"] == .array([.number(1), .number(2)]))
        let failed = try decode(ToolCallResult.self, #"{"is_error":true,"content":[{"type":"text","text":"bad"}]}"#)
        #expect(failed.isError && failed.structured == nil)
    }

    @Test func theCallsGoToTheirMethodsWithTheRightParams() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: [
            "integrations.calls": { _ in "[]" },
            "integrations.call_stats": { _ in "[]" },
            "integrations.call_tool": { _ in #"{"is_error":false,"content":[]}"# },
        ]))
        let (model, _) = makeModel([fake])
        await model.connect()
        _ = try await model.toolCalls(integration: "linear", agentID: "a1", limit: 30, before: 99)
        _ = try await model.toolCallStats()
        // The names of the arguments are the tool's own: they keep their spelling, camel or snake.
        _ = try await model.callTool(
            "i1", tool: "save_issue", arguments: .object(["projectId": .number(3), "due_date": .string("x")]))
        let texts = await fake.sentTexts()
        let callsText = try #require(JSONRPC.requests(of: "integrations.calls", in: texts).first)
        let calls = try #require(JSONRPC.parse(callsText)).paramsJSON
        let params = try #require(JSONSerialization.jsonObject(with: Data(calls.utf8)) as? [String: Any])
        #expect(params["integration"] as? String == "linear" && params["agent_id"] as? String == "a1")
        #expect(params["limit"] as? Int == 30 && params["before"] as? Int == 99)
        let toolText = try #require(JSONRPC.requests(of: "integrations.call_tool", in: texts).first)
        let tool = try #require(JSONRPC.parse(toolText)).paramsJSON
        let sent = try #require(JSONSerialization.jsonObject(with: Data(tool.utf8)) as? [String: Any])
        #expect(sent["id"] as? String == "i1" && sent["tool"] as? String == "save_issue")
        let args = try #require(sent["arguments"] as? [String: Any])
        #expect(Set(args.keys) == ["projectId", "due_date"])
        await model.disconnect()
    }
}
