import Foundation
import Testing

@testable import BanditoKit

/// `tool_mode` and `tool_overrides` of an integration, their patch, and `integrations.tools`.
@MainActor
@Suite struct ToolPermissionsWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    private func json(_ patch: IntegrationPatch) throws -> [String: Any] {
        struct Wrapper: Encodable {
            var patch: IntegrationPatch
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: IntegrationPatch.Key.self)
                try patch.encodeFields(into: &c)
            }
        }
        let data = try RPCClient.encoder.encode(Wrapper(patch: patch))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test func anIntegrationReadsItsModeAndItsWords() throws {
        let row = try decode(
            Integration.self,
            #"{"id":"i","name":"x","kind":"http","tool_mode":"confirm_writes","tool_overrides":{"create_issue":"deny","listProjects":"allow"}}"#)
        #expect(row.toolMode == .confirmWrites)
        // Tool names keep their spelling, snake or camel.
        #expect(row.toolOverrides == ["create_issue": .deny, "listProjects": .allow])
        let readOnly = try decode(Integration.self, #"{"id":"i","name":"x","kind":"http","tool_mode":"read_only"}"#)
        #expect(readOnly.toolMode == .readOnly)
    }

    @Test func anOldDaemonMeansEverything() throws {
        let row = try decode(Integration.self, #"{"id":"i","name":"x","kind":"http"}"#)
        #expect(row.toolMode == .all)
        #expect(row.toolOverrides.isEmpty)
    }

    @Test func aModeOrAWordTheAppDoesNotKnowReadsCarefully() throws {
        let row = try decode(
            Integration.self,
            #"{"id":"i","name":"x","kind":"http","tool_mode":"paranoid","tool_overrides":{"a":"maybe","b":"allow"}}"#)
        #expect(row.toolMode == .confirmWrites)
        #expect(row.toolOverrides["a"] == .ask)
        #expect(row.toolOverrides["b"] == .allow)
    }

    @Test func aPatchSendsSnakeCaseKeysAndKeepsToolNames() throws {
        let body = try json(IntegrationPatch(toolMode: .readOnly, toolOverrides: ["createIssue": .ask, "drop_all": .deny]))
        #expect(body["tool_mode"] as? String == "read_only")
        let words = try #require(body["tool_overrides"] as? [String: String])
        #expect(words == ["createIssue": "ask", "drop_all": "deny"])
        #expect(try json(IntegrationPatch(enabled: false))["tool_mode"] == nil)
        #expect(try json(IntegrationPatch(enabled: false))["tool_overrides"] == nil)
        // An empty map is sent: it clears the words.
        #expect((try json(IntegrationPatch(toolOverrides: [:]))["tool_overrides"] as? [String: String]) == [:])
    }

    @Test func theToolsOfAServiceDecode() async throws {
        let raw = ##"[{"name":"search","title":"Search","description":"Finds things","read_only":true,"destructive":false,"input_schema":{"type":"object"},"seen_at":5},{"name":"drop","title":null,"description":null,"read_only":false,"destructive":true,"input_schema":null,"seen_at":5}]"##
        let tools = try decode([IntegrationTool].self, raw)
        #expect(tools.map(\.name) == ["search", "drop"])
        #expect(tools[0].readOnly && !tools[0].destructive)
        #expect(tools[1].destructive && !tools[1].readOnly)
        #expect(tools[0].title == "Search")
        #expect(tools[1].title == nil)
        #expect(tools[1].inputSchema == nil)
        let fake = FakeTransport(handlers: daemonHandlers(extra: ["integrations.tools": { _ in raw }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        let listed = try await model.integrationTools("i1")
        #expect(listed.count == 2)
        let sent = JSONRPC.requests(of: "integrations.tools", in: await fake.sentTexts())
        #expect(try #require(JSONRPC.parse(sent[0])).paramsJSON.contains("\"id\":\"i1\""))
        await model.disconnect()
    }
}
