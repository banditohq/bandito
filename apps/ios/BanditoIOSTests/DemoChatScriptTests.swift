import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// The demo agents answer the person: a streamed reply, an approval that holds the turn, a stop, and the two buttons.
@MainActor
@Suite(.serialized) struct DemoChatScriptTests {
    func forge(_ server: ServerModel) -> String {
        server.agents.first { $0.name == "Forge" }?.id ?? ""
    }

    func waitUntil(_ limit: Int = 600, _ done: () -> Bool) async {
        var waited = 0
        while !done(), waited < limit {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
    }

    func fast(_ server: ServerModel) {
        IOSDemo.scripts[server.id]?.pace = .milliseconds(5)
        IOSDemo.scripts[server.id]?.tokenPace = .milliseconds(1)
    }

    @Test func aMessageGetsAStreamedReplyWithButtons() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        fast(server)
        let agent = forge(server)
        try await server.send("Look around the project", to: agent)
        await waitUntil { server.thread(for: agent).items.contains { if case .assistant(_, let text, _) = $0 { return text.contains("retries") } else { return false } } }
        let thread = server.thread(for: agent)
        let reply = thread.items.compactMap { item -> String? in
            if case .assistant(_, let text, _) = item { return text.contains("retries") ? text : nil }
            return nil
        }.first
        #expect(reply?.contains("```swift") == true)
        // Three commands ran before it spoke, and its turn is over with the agent's buttons offered.
        #expect(thread.items.filter { if case .tool = $0 { return true } else { return false } }.count >= 3)
        await waitUntil { !server.thread(for: agent).turnRunning }
        #expect(!server.thread(for: agent).turnRunning)
        #expect(server.thread(for: agent).quickReplies?.buttons.count == 2)
        // The stream was replaced by the final message.
        #expect(!server.thread(for: agent).items.contains { if case .streaming = $0 { return true } else { return false } })
    }

    @Test func aRequestHoldsTheTurnUntilItIsAnswered() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        fast(server)
        let agent = forge(server)
        try await server.send("Run the tests", to: agent)
        await waitUntil { server.thread(for: agent).pendingApprovals.contains { $0.approvalId == "demo-script-approval-1" } }
        #expect(server.thread(for: agent).pendingApprovals.contains { $0.approvalId == "demo-script-approval-1" })
        // No reply yet: it waits for the answer.
        #expect(!server.thread(for: agent).items.contains { if case .assistant(_, let text, _) = $0 { return text.contains("retries") } else { return false } })
        try await server.resolve("demo-script-approval-1", .allow)
        await waitUntil { server.thread(for: agent).items.contains { if case .assistant(_, let text, _) = $0 { return text.contains("retries") } else { return false } } }
        #expect(server.thread(for: agent).items.contains { if case .assistant(_, let text, _) = $0 { return text.contains("retries") } else { return false } })
    }

    @Test func aDeniedRequestEndsTheTurnWithoutRunningTheTests() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        fast(server)
        let agent = forge(server)
        try await server.send("Please push", to: agent)
        await waitUntil { server.thread(for: agent).pendingApprovals.contains { $0.approvalId == "demo-script-approval-1" } }
        try await server.resolve("demo-script-approval-1", .deny)
        await waitUntil { server.thread(for: agent).items.contains { if case .assistant(_, let text, _) = $0 { return text.contains("did not run") } else { return false } } }
        #expect(server.thread(for: agent).items.contains { if case .assistant(_, let text, _) = $0 { return text.contains("did not run") } else { return false } })
    }

    @Test func stopEndsTheTurn() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        IOSDemo.scripts[server.id]?.pace = .milliseconds(200)
        let agent = forge(server)
        try await server.send("Look around", to: agent)
        await waitUntil { server.thread(for: agent).turnRunning }
        try await server.interrupt(agent)
        await waitUntil { !server.thread(for: agent).turnRunning }
        #expect(!server.thread(for: agent).turnRunning)
        #expect(server.thread(for: agent).items.contains { if case .note(_, _, _, _) = $0 { return true } else { return false } })
    }
}
