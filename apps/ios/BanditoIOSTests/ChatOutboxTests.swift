import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// What the person wrote without a connection: it waits, goes out in order, once, when the connection is there.
@MainActor
@Suite(.serialized) struct ChatOutboxTests {
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [DemoClientCall] = []
        var sends: [String] { lock.withLock { list.filter { $0.method == "agents.send" }.compactMap(\.text) } }
        func add(_ call: DemoClientCall) { lock.withLock { list.append(call) } }
    }

    func offlineServer() async -> (ServerModel, Heard) {
        let (server, transport) = DemoDaemon.server(
            id: UUID(), name: "Offline", setup: DemoDaemonSetup(agentIDs: ["a1"], hostname: "demo"))
        let heard = Heard()
        await transport.setClientHook { call in heard.add(call) }
        // Not connected yet: the model starts disconnected.
        return (server, heard)
    }

    func waitUntil(_ limit: Int = 400, _ done: () -> Bool) async {
        var waited = 0
        while !done(), waited < limit {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
    }

    @Test func messagesWrittenOfflineWaitAndGoOutInOrderOnceWhenTheConnectionComes() async {
        let (server, heard) = await offlineServer()
        let outbox = ChatOutbox(file: nil)
        outbox.attach([server])
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "one")
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "two")
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "three")
        try? await Task.sleep(for: .milliseconds(150))
        // Nothing left the phone, and all three are kept as waiting.
        #expect(heard.sends.isEmpty)
        #expect(outbox.items(serverID: server.id, agentID: "a1").map(\.state) == [.waiting, .waiting, .waiting])

        await server.connect()
        await waitUntil { heard.sends.count >= 3 }
        #expect(heard.sends == ["one", "two", "three"])
        // Each came back as the person's message; the queue lets go of them (the pending rows would double them).
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").isEmpty }
        #expect(outbox.items(serverID: server.id, agentID: "a1").isEmpty)
        // And once more: nothing is sent twice.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(heard.sends == ["one", "two", "three"])
    }

    @Test func aMessageWrittenWhileConnectedGoesAtOnce() async {
        let (server, heard) = await offlineServer()
        await server.connect()
        let outbox = ChatOutbox(file: nil)
        outbox.attach([server])
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "now")
        await waitUntil { !heard.sends.isEmpty }
        #expect(heard.sends == ["now"])
    }

    @Test func theQueueIsKeptInAFileAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = SendQueueFile(url: url)
        let first = ChatOutbox(file: file)
        let id = UUID()
        first.enqueue(serverID: id, agentID: "a1", text: "kept")
        let second = ChatOutbox(file: file)
        #expect(second.items(serverID: id, agentID: "a1").map(\.text) == ["kept"])
    }

    @Test func anAnswerThatNeverComesAsAnEventDoesNotStayForever() async {
        let (server, heard) = await offlineServer()
        await server.connect()
        let outbox = ChatOutbox(file: nil)
        outbox.echoTimeout = .milliseconds(100)
        outbox.attach([server])
        // The demo echoes the person's text as an event: send text it will echo, then check that a sent one is let go
        // even when no thread looks at it (nothing releases it but the timeout).
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "kept briefly")
        await waitUntil { !heard.sends.isEmpty }
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").isEmpty }
        #expect(outbox.items(serverID: server.id, agentID: "a1").isEmpty)
    }

    @Test func aRefusalIsTold_ALostLinkIsNot() {
        #expect(!ChatOutbox.isAmbiguousLoss(RPCError(code: RPCError.invalidParams, message: "bad")))
        #expect(ChatOutbox.isAmbiguousLoss(RPCError(code: RPCError.disconnected, message: "closed")))
        #expect(ChatOutbox.isAmbiguousLoss(RPCError(code: RPCError.timedOut, message: "slow")))
        #expect(ChatOutbox.isAmbiguousLoss(URLError(.networkConnectionLost)))
    }
}
