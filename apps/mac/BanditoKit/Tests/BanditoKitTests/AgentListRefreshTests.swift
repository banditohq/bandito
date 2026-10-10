import Foundation
import Testing

@testable import BanditoKit

/// Counts the `agents.list` calls a fake daemon answers, and what they answer.
// @unchecked: guarded by `lock`.
final class AgentListDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: String
    private(set) var calls = 0

    init(_ answer: String) {
        self.answer = answer
    }

    func set(_ answer: String) {
        lock.withLock { self.answer = answer }
    }

    func handler() -> FakeTransport.Handler {
        { [self] _ in
            lock.withLock {
                calls += 1
                return answer
            }
        }
    }

    var callCount: Int {
        lock.withLock { calls }
    }
}

private func agentJSON(_ id: String, _ name: String) -> String {
    #"{"id":"\#(id)","name":"\#(name)","runtime":"claude","cwd":"/x","pending_approvals":0,"last_message":null}"#
}

@MainActor
@Suite struct AgentListRefreshTests {
    /// Waits long enough for a debounced refresh that should not come.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    @Test func eventFromAnUnknownAgentReadsTheListOnce() async throws {
        let daemon = AgentListDaemon("[]")
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": daemon.handler()]))
        let (model, _) = makeModel([fake])
        await model.connect()
        #expect(daemon.callCount == 1, "the connect read the list once")

        // Made on another device: the list does not have it yet.
        daemon.set("[\(agentJSON("x", "Remote"))]")
        for seq in 43...45 {
            await fake.push(
                JSONRPC.notification(
                    #"{"seq":\#(seq),"agent_id":"x","ts":\#(seq),"kind":"agent.status","payload":{"status":"idle"}}"#))
        }
        try await eventually { daemon.callCount == 2 }
        await settle()
        #expect(daemon.callCount == 2, "three events in a burst make one read")
        #expect(model.agents.map(\.id) == ["x"])
        await model.disconnect()
    }

    @Test func agentChangedCreatedAndUpdatedReadTheList() async throws {
        let daemon = AgentListDaemon(#"[\#(agentJSON("a", "Forge"))]"#)
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": daemon.handler()]))
        let (model, _) = makeModel([fake])
        await model.connect()

        await fake.push(
            JSONRPC.notification(
                #"{"seq":43,"agent_id":"a","ts":43,"kind":"agent_changed","payload":{"action":"updated"}}"#))
        try await eventually { daemon.callCount == 2 }
        await fake.push(
            JSONRPC.notification(
                #"{"seq":44,"agent_id":"b","ts":44,"kind":"agent_changed","payload":{"action":"created"}}"#))
        try await eventually { daemon.callCount == 3 }
        await settle()
        #expect(daemon.callCount == 3)
        await model.disconnect()
    }

    @Test func agentChangedDeletedRemovesTheAgentWithoutAReadAndKeepsTheRest() async throws {
        let list = "[\(agentJSON("a", "Forge")),\(agentJSON("b", "Scout"))]"
        let daemon = AgentListDaemon(list)
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": daemon.handler()]))
        let (model, _) = makeModel([fake])
        await model.connect()
        #expect(model.agents.map(\.id) == ["a", "b"])

        await fake.push(
            JSONRPC.notification(
                #"{"seq":43,"agent_id":"a","ts":43,"kind":"agent_changed","payload":{"action":"deleted"}}"#))
        try await eventually { model.agents.map(\.id) == ["b"] }
        await settle()
        #expect(daemon.callCount == 1, "a deletion needs no read")
        await model.disconnect()
    }

    @Test func staleAgentsAreReadWhenTheAppComesBack() async throws {
        let daemon = AgentListDaemon("[]")
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": daemon.handler()]))
        let (model, _) = makeModel([fake])
        await model.connect()
        let read = try #require(model.agentsReadAt)

        model.refreshAgentsIfStale(now: read.addingTimeInterval(10))
        await settle()
        #expect(daemon.callCount == 1, "a recent read is kept")

        model.refreshAgentsIfStale(now: read.addingTimeInterval(31))
        try await eventually { daemon.callCount == 2 }
        await model.disconnect()
    }

    /// A deletion makes every read asked for before it stale; reads asked for after it are kept.
    @Test func aDeletionMakesEarlierReadsStale() {
        var generation = ListGeneration()
        let asked = generation
        #expect(generation.accepts(asked))
        generation.advance()
        #expect(!generation.accepts(asked), "an answer to a read asked before the deletion is dropped")
        #expect(generation.accepts(generation), "a read asked after it is kept")
    }

    @Test func aFailedReadCountsAsARead() async throws {
        let failing = Switch(on: false)
        let daemon = AgentListDaemon("[]")
        let fake = FakeTransport(
            handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": daemon.handler()]),
            errors: ["agents.list": { _ in failing.isOn ? #"{"code":-32000,"message":"boom"}"# : nil }])
        let (model, _) = makeModel([fake], reconnectDelay: .milliseconds(10))
        await model.connect()
        model.agentsRetryDelay = .seconds(600)

        failing.set(true)
        model.refreshAgentsIfStale(now: Date().addingTimeInterval(31))
        try await eventually { model.agentsReadAt.map { Date().timeIntervalSince($0) < 5 } ?? false }
        #expect(daemon.callCount == 1, "the failed read did not answer")

        // The app comes back to the front again: the failure was just now, so nothing is asked again.
        model.refreshAgentsIfStale()
        await settle()
        #expect(daemon.callCount == 1)
        await model.disconnect()
    }

    @Test func aFailedReadIsAskedAgainAfterTheDelay() async throws {
        let failing = Switch(on: false)
        let daemon = AgentListDaemon("[\(agentJSON("a", "Forge"))]")
        let fake = FakeTransport(
            handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": daemon.handler()]),
            errors: ["agents.list": { _ in failing.isOn ? #"{"code":-32000,"message":"boom"}"# : nil }])
        let (model, _) = makeModel([fake], reconnectDelay: .milliseconds(10))
        await model.connect()
        model.agentsRetryDelay = .milliseconds(50)

        failing.set(true)
        model.refreshAgentsIfStale(now: Date().addingTimeInterval(31))
        try await Task.sleep(for: .milliseconds(120))
        failing.set(false)
        try await eventually { daemon.callCount == 2 }
        #expect(model.agents.map(\.id) == ["a"])
        await model.disconnect()
    }
}

/// A switch a test flips while the daemon answers.
// @unchecked: guarded by `lock`.
final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool

    init(on: Bool) {
        self.on = on
    }

    func set(_ value: Bool) {
        lock.withLock { on = value }
    }

    var isOn: Bool {
        lock.withLock { on }
    }
}
