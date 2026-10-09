import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders key screens to PNG (no window, no app) so changes can be reviewed as
/// images. Rendering helper: `SnapshotSupport`.
@MainActor
@Suite struct Snapshots {
    static func demoServer() -> (ServerModel, Agent) {
        let server = ServerModel(config: ServerConfig(name: "vps-tokyo-1", endpoint: .defaultLocal))
        let agent = Agent(
            id: "forge", name: "Forge", role: "builder", runtime: .claude, model: nil, cwd: "/home/me/billing",
            approvalMode: .risky, systemPrompt: nil, runtimeSessionId: nil, createdAt: 0, updatedAt: 0)
        var seq: Int64 = 0
        func ev(_ b: EventBody) -> Event {
            seq += 1
            return Event(seq: seq, agentId: "forge", ts: 1_791_530_000_000 + seq * 1000, body: b)
        }
        let events: [EventBody] = [
            .turnStarted(turnId: "t", source: .user),
            .messageUser(text: "Add tests for the billing webhook and open a PR.", source: .user, fromAgent: nil),
            .agentStatus(status: .working, detail: nil),
            .messageAssistant(text: "Wrote 14 tests. Two failed on currency rounding — fixed by keeping amounts in cents."),
            .toolCall(callId: "c1", tool: "Bash", title: "cargo test billing::", input: .null),
            .toolResult(callId: "c1", ok: true, output: "test result: ok. 14 passed"),
            .toolCall(callId: "c2", tool: "Bash", title: "git push origin feat/billing-webhook-tests", input: .null),
            .approvalRequested(
                approvalId: "ap1", callId: "c2", tool: "Bash", title: "git push origin feat/billing-webhook-tests",
                command: "git push origin feat/billing-webhook-tests", diff: nil, reason: "risky: git push*"),
            .agentStatus(status: .needsYou, detail: nil),
        ]
        for b in events { server.apply(ev(b)) }
        return (server, agent)
    }

    @Test func threadWithApproval() throws {
        let (server, agent) = Self.demoServer()
        // ScrollView and text fields are AppKit-backed and don't render offscreen: snapshot the rows.
        let view = ThreadItemsView(items: server.thread(for: agent.id).items, server: server)
            .background(Color(red: 0.07, green: 0.063, blue: 0.055))
        let url = try SnapshotSupport.render(view, "thread-approval", size: CGSize(width: 900, height: 640))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func sidebarRows() throws {
        let (server, agent) = Self.demoServer()
        let rows = VStack(alignment: .leading, spacing: 4) {
            AgentRow(agent: agent, thread: server.thread(for: agent.id))
            AgentRow(
                agent: Agent(
                    id: "scout", name: "Scout", role: "reviewer", runtime: .codex, model: nil, cwd: "/home/me/api",
                    approvalMode: .risky, systemPrompt: nil, runtimeSessionId: nil, createdAt: 0, updatedAt: 0),
                thread: AgentThread())
        }
        .padding()
        .background(Color.black)
        _ = try SnapshotSupport.render(rows, "sidebar-rows", size: CGSize(width: 280, height: 140))
    }
}
