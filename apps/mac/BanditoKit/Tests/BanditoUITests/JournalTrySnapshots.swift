import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders the journal and the form of "Try" to PNG (no window, no app), to look at them.
@MainActor
@Suite struct JournalTrySnapshots {
    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(raw.utf8))
    }

    @Test func journal() throws {
        let agent = try decode(Agent.self, #"{"id":"a","name":"Forge","runtime":"claude","cwd":"/x"}"#)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let day = Int64(3_600_000)
        let rows = [
            ToolCallRecord(id: 100, atMs: now, agentId: "a", integration: "linear", tool: "list_issues", durationMs: 340, ok: true, decision: .allowed),
            ToolCallRecord(id: 99, atMs: now - day, agentId: "a", integration: "linear", tool: "save_issue", durationMs: 1200, ok: false, error: "rate limited, try again in a minute", decision: .asked),
            ToolCallRecord(id: 98, atMs: now - 2 * day, agentId: "a", integration: "linear", tool: "list_issues", decision: .allowed),
            ToolCallRecord(id: 97, atMs: now - 30 * day, agentId: "a", integration: "linear", tool: "delete_comment", decision: .denied),
        ]
        var journal = CallJournal()
        journal.replace(with: rows)
        let input = JournalSectionInput(
            journal: journal, loading: false, error: nil, agents: [agent], server: nil, onMore: {})
        let view = CallJournalBody(input: input).padding(20).frame(width: 640).background(Color.Bandito.surface1)
        let url = try SnapshotSupport.render(view, "market-journal", size: CGSize(width: 640, height: 340))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func tryForm() throws {
        let schema = try decode(
            JSONValue.self,
            ##"{"type":"object","required":["title"],"properties":{"title":{"type":"string","description":"The title of the issue."},"priority":{"type":"integer"},"state":{"type":"string","enum":["open","closed"]},"labels":{"type":"array"}}}"##)
        let tool = IntegrationTool(name: "save_issue", readOnly: false, inputSchema: schema)
        let view = ToolTryView(tool: tool, service: "Linear") { _ in .failure(UserFacingMessage(text: "x")) }
            .padding(20).frame(width: 640).background(Color.Bandito.surface1)
        let url = try SnapshotSupport.render(view, "market-try-form", size: CGSize(width: 640, height: 460))
        #expect(FileManager.default.fileExists(atPath: url.path))
        let answer = ToolTryResultView(
            outcome: .answer(
                ToolCallResult(
                    isError: true, content: [ToolContentPart(type: "text", text: "Validation failed: title is too long")],
                    structured: .object(["code": .number(422), "field": .string("title")]))))
            .padding(20).frame(width: 640).background(Color.Bandito.surface1)
        let second = try SnapshotSupport.render(answer, "market-try-result", size: CGSize(width: 640, height: 300))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
