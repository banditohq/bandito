import Foundation
import Testing

@testable import BanditoKit

/// Hands out transports in order: the first connection gets the first one, a reconnect the next.
final class TransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [FakeTransport]
    private(set) var made: [FakeTransport] = []

    init(_ transports: [FakeTransport]) {
        pending = transports
    }

    func next() -> RPCTransport {
        lock.withLock {
            let transport = pending.isEmpty ? FakeTransport(handlers: daemonHandlers()) : pending.removeFirst()
            made.append(transport)
            return transport
        }
    }
}

/// Handlers for the daemon calls every connection makes, plus `extra` (which wins).
func daemonHandlers(
    lastSeq: Int64 = 42, extra: [String: FakeTransport.Handler] = [:]
) -> [String: FakeTransport.Handler] {
    var handlers: [String: FakeTransport.Handler] = [
        "daemon.info": { _ in
            #"{"version":"0.0.0","hostname":"test","os":"macos","arch":"arm64","started_at":1,"last_seq":\#(lastSeq)}"#
        },
        "agents.list": { _ in "[]" },
        "runtimes.status": { _ in "[]" },
        "events.subscribe": { _ in #"{"last_seq":\#(lastSeq)}"# },
    ]
    handlers.merge(extra) { _, new in new }
    return handlers
}

@MainActor
func makeModel(
    _ transports: [FakeTransport], reconnectDelay: Duration = .milliseconds(10)
) -> (ServerModel, TransportQueue) {
    let queue = TransportQueue(transports)
    let model = ServerModel(
        config: ServerConfig(name: "test", endpoint: .local(socketPath: "unused")),
        makeTransport: { _ in queue.next() },
        reconnectDelay: { _ in reconnectDelay })
    return (model, queue)
}

/// `count` events for one agent, seq `from...to`, as a JSON array.
func eventPage(_ seqs: ClosedRange<Int>) -> String {
    "[" + seqs.map { JSONRPC.messageEvent(seq: $0, text: "m\($0)") }.joined(separator: ",") + "]"
}

@MainActor
@Suite struct ServerModelTests {
    @Test func firstConnectSubscribesOnlyToLiveEvents() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42))
        let (model, _) = makeModel([fake])

        await model.connect()

        #expect(model.state == .connected)
        #expect(model.info?.lastSeq == 42)
        let subscribes = JSONRPC.requests(of: "events.subscribe", in: await fake.sentTexts())
        #expect(subscribes.count == 1)
        #expect(JSONRPC.intParam("after", in: subscribes[0]) == 42)
        await model.disconnect()
    }

    @Test func gapIsFilledFromSinceBeforeTheLiveEventIsApplied() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(
                lastSeq: 42,
                extra: ["events.since": { params in params.contains("\"after\":42") ? eventPage(43...45) : "[]" }]))
        let (model, _) = makeModel([fake])
        await model.connect()

        // 43 and 44 never arrived live: 45 must not be applied before them.
        await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 45, text: "m45")))

        try await eventually { model.thread(for: "a").items.count == 3 }
        #expect(model.thread(for: "a").items.map(\.id) == ["s43", "s44", "s45"])
        let since = JSONRPC.requests(of: "events.since", in: await fake.sentTexts())
        #expect(!since.isEmpty)
        #expect(JSONRPC.intParam("after", in: since[0]) == 42)
        await model.disconnect()
    }

    @Test func lostConnectionReconnectsAndResubscribesFromLastSeq() async throws {
        let first = FakeTransport(handlers: daemonHandlers(lastSeq: 42))
        let second = FakeTransport(handlers: daemonHandlers(lastSeq: 43))
        let (model, queue) = makeModel([first, second], reconnectDelay: .milliseconds(300))
        await model.connect()
        await first.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 43, text: "last words")))
        try await eventually { model.thread(for: "a").items.count == 1 }

        await first.dropConnection()

        try await eventually { model.state == .reconnecting(attempt: 1) }
        try await eventually { model.state == .connected }
        #expect(queue.made.count == 2)
        let subscribes = JSONRPC.requests(of: "events.subscribe", in: await second.sentTexts())
        #expect(subscribes.count == 1)
        #expect(JSONRPC.intParam("after", in: subscribes.first ?? "") == 43)
        await model.disconnect()
    }

    @Test func disconnectStopsReconnecting() async throws {
        let first = FakeTransport(handlers: daemonHandlers())
        let (model, queue) = makeModel([first], reconnectDelay: .milliseconds(20))
        await model.connect()
        await first.dropConnection()
        try await eventually { model.state == .reconnecting(attempt: 1) }

        await model.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        #expect(model.state == .disconnected)
        #expect(queue.made.count == 1)
    }

    @Test func connectWhileConnectedReusesTheConnection() async throws {
        let fake = FakeTransport(handlers: daemonHandlers())
        let (model, queue) = makeModel([fake])

        await model.connect()
        await model.connect()

        #expect(queue.made.count == 1)
        #expect(model.state == .connected)
        await model.disconnect()
    }

    @Test func loadHistoryKeepsLiveStreamAndTurnState() async throws {
        let page =
            "["
            + [
                #"{"seq":1,"agent_id":"a","ts":1,"kind":"message.user","payload":{"text":"hi","source":"user"}}"#,
                JSONRPC.messageEvent(seq: 2, text: "hello"),
            ].joined(separator: ",") + "]"
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["events.page": { _ in page }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        await fake.push(
            JSONRPC.notification(
                #"{"seq":43,"agent_id":"a","ts":3,"kind":"turn.started","payload":{"turn_id":"t","source":"user"}}"#))
        await fake.push(
            JSONRPC.notification(#"{"seq":0,"agent_id":"a","ts":4,"kind":"message.delta","payload":{"text":"Hel"}}"#))
        try await eventually { model.thread(for: "a").items.last == .streaming(text: "Hel") }

        try await model.loadHistory("a")

        let thread = model.thread(for: "a")
        #expect(thread.turnRunning)
        #expect(thread.items.last == .streaming(text: "Hel"))
        #expect(thread.items.contains(.assistant(id: "s2", text: "hello", ts: 2)))
        await model.disconnect()
    }

    @Test func olderHistoryIsPagedAndPrepended() async throws {
        let newest = eventPage(101...300)
        let older = eventPage(1...100)
        let fake = FakeTransport(
            handlers: daemonHandlers(
                lastSeq: 300,
                extra: ["events.page": { params in params.contains("\"before\"") ? older : newest }]))
        let (model, _) = makeModel([fake])
        await model.connect()

        try await model.loadHistory("a")
        #expect(model.hasMoreHistory["a"] == true)
        #expect(model.thread(for: "a").items.count == 200)

        try await model.loadOlder("a")
        #expect(model.hasMoreHistory["a"] == false)
        #expect(model.thread(for: "a").items.count == 300)
        #expect(model.thread(for: "a").items.first?.id == "s1")
        await model.disconnect()
    }

    @Test func undecodableEventSetsLastError() async throws {
        let fake = FakeTransport(handlers: daemonHandlers())
        let (model, _) = makeModel([fake])
        await model.connect()

        await fake.push(
            #"{"jsonrpc":"2.0","method":"event","params":{"seq":"oops","agent_id":"a","ts":1,"kind":"message.assistant","payload":{"text":"x"}}}"#)
        try await eventually { model.lastError == ServerModel.decodeWarning }
        await model.disconnect()
    }

    @Test func usageEventsUpdateTheCache() {
        let (model, _) = makeModel([])
        model.apply(
            Event(
                seq: 1, agentId: "a", ts: 1,
                body: .usageLimits(runtime: "claude", windows: [LimitWindow(name: "5h", utilization: 0.4, resetsAt: nil)])))
        model.apply(
            Event(
                seq: 2, agentId: "a", ts: 2,
                body: .usageLimits(runtime: "claude", windows: [LimitWindow(name: "5h", utilization: 0.9, resetsAt: nil)])))

        #expect(model.usage.count == 1)
        #expect(model.usage.first?.windows.first?.utilization == 0.9)
    }
}
