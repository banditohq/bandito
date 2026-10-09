import Foundation
import Testing

@testable import BanditoKit

/// Hands out transports in order: the first connection gets the first one, a reconnect the next.
// @unchecked: `pending` and `made` are guarded by `lock`.
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

    /// The sidebar preview is the daemon's `last_message`, and a live message replaces it without a reload.
    @Test func liveMessagesKeepTheAgentsLastMessageCurrent() async throws {
        let agents =
            #"[{"id":"a","name":"Forge","runtime":"claude","cwd":"/x","#
            + #""last_message":{"role":"assistant","text":"old","ts":5}}]"#
        let fake = FakeTransport(
            handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": { _ in agents }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        #expect(model.agents.first?.lastMessage == LastMessage(role: "assistant", text: "old", ts: 5))

        await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 43, text: "new")))
        try await eventually { model.agents.first?.lastMessage?.text == "new" }
        #expect(model.agents.first?.lastMessage?.ts == 43)

        // Bandito's own wrap-up message is not a preview, and neither is a tool call or a delta.
        await fake.push(
            JSONRPC.notification(
                #"{"seq":44,"agent_id":"a","ts":44,"kind":"message.user","payload":{"text":"save memory","source":"system"}}"#))
        await fake.push(
            JSONRPC.notification(#"{"seq":0,"agent_id":"a","ts":45,"kind":"message.delta","payload":{"text":"Hi"}}"#))
        await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 45, text: "last")))
        try await eventually { model.agents.first?.lastMessage?.text == "last" }
        #expect(model.agents.first?.lastMessage?.ts == 45)
        await model.disconnect()
    }

    /// An agent that waits for an approval is "needs you" before anyone opens its thread: the daemon's list carries
    /// the status and the count, and the sidebar and the menu bar read them without any thread.
    @Test func agentWaitingForAnApprovalIsNeedsYouBeforeItsThreadIsOpened() async throws {
        let agents =
            #"[{"id":"a","name":"Forge","runtime":"claude","cwd":"/x","status":"needs_you","pending_approvals":1,"#
            + #""last_message":null},{"id":"b","name":"Scout","runtime":"claude","cwd":"/y","status":"idle","#
            + #""pending_approvals":0,"last_message":null}]"#
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": { _ in agents }]))
        let (model, _) = makeModel([fake])
        await model.connect()

        #expect(model.threads["a"] == nil, "no thread is loaded")
        #expect(model.status(of: "a") == .needsYou)
        #expect(model.pendingApprovalCount(of: "a") == 1)
        #expect(model.needsPerson("a"))
        #expect(!model.needsPerson("b"))
        // Sorted like the sidebar's "needs you" group: Forge first, although Scout comes first by name.
        #expect(model.sortedAgents.map(\.id) == ["a", "b"])
        // The menu bar lists approvals only for loaded threads; this one is counted with no row.
        #expect(model.pendingApprovalCount(of: "a") - model.thread(for: "a").pendingApprovals.count == 1)
        await model.disconnect()
    }

    /// Approvals and status that arrive live keep the team's view current, with no thread loaded.
    @Test func liveApprovalAndStatusEventsUpdateTheTeamView() async throws {
        let agents = #"[{"id":"a","name":"Forge","runtime":"claude","cwd":"/x","pending_approvals":0,"last_message":null}]"#
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": { _ in agents }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        #expect(!model.needsPerson("a"))

        await fake.push(
            JSONRPC.notification(
                #"{"seq":43,"agent_id":"a","ts":43,"kind":"approval.requested","payload":{"approval_id":"ap1","call_id":"c1","tool":"Bash","title":"git push","reason":"risky"}}"#))
        try await eventually { model.pendingApprovalCount(of: "a") == 1 }
        #expect(model.needsPerson("a"))

        await fake.push(
            JSONRPC.notification(
                #"{"seq":44,"agent_id":"a","ts":44,"kind":"agent.status","payload":{"status":"needs_you"}}"#))
        try await eventually { model.status(of: "a") == .needsYou }

        await fake.push(
            JSONRPC.notification(
                #"{"seq":45,"agent_id":"a","ts":45,"kind":"approval.resolved","payload":{"approval_id":"ap1","decision":"allow","by":"user","remember":false}}"#))
        try await eventually { model.pendingApprovalCount(of: "a") == 0 }
        #expect(model.status(of: "a") == .needsYou, "the status is the agent's own, not the approval's")
        await model.disconnect()
    }

    /// A daemon from before `last_message` sends no such field: the app reads the newest messages once per agent.
    @Test func daemonWithoutLastMessageGetsOneLegacyPreviewRead() async throws {
        let agents = #"[{"id":"a","name":"Forge","runtime":"claude","cwd":"/x"}]"#
        let fake = FakeTransport(
            handlers: daemonHandlers(
                lastSeq: 42,
                extra: [
                    "agents.list": { _ in agents },
                    "events.page": { _ in
                        "[" + JSONRPC.messageEvent(seq: 40, text: "older") + ","
                            + JSONRPC.messageEvent(seq: 41, text: "newest") + "]"
                    },
                ]))
        let (model, _) = makeModel([fake])
        await model.connect()

        try await eventually { model.agents.first?.lastMessage?.text == "newest" }
        #expect(model.agents.first?.reportsLastMessage == true)
        let pages = JSONRPC.requests(of: "events.page", in: await fake.sentTexts())
        #expect(pages.count == 1)
        #expect(JSONRPC.intParam("limit", in: pages[0]) == ServerModel.legacyPreviewPageSize)
        await model.disconnect()
    }

    /// A daemon with the field (even when null) is not asked for messages again.
    @Test func daemonWithLastMessageIsNotReadAgain() async throws {
        let agents = #"[{"id":"a","name":"Forge","runtime":"claude","cwd":"/x","last_message":null}]"#
        let fake = FakeTransport(
            handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": { _ in agents }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.agents.first?.reportsLastMessage == true)
        #expect(JSONRPC.requests(of: "events.page", in: await fake.sentTexts()).isEmpty)
        await model.disconnect()
    }

    /// The approvals are counted by id, so a replayed `approval.requested` does not count twice, and a resolution
    /// removes the id whichever copy of the event arrives.
    @Test func replayedApprovalEventsDoNotCountTwice() async throws {
        let agents =
            #"[{"id":"a","name":"Forge","runtime":"claude","cwd":"/x","pending_approval_ids":["A"],"pending_approvals":1,"#
            + #""last_message":null}]"#
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": { _ in agents }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        #expect(model.pendingApprovalCount(of: "a") == 1, "the snapshot's id")

        let requested =
            #"{"approval_id":"A","call_id":"c1","tool":"Bash","title":"git push","reason":"risky"}"#
        await fake.push(JSONRPC.notification(#"{"seq":43,"agent_id":"a","ts":43,"kind":"approval.requested","payload":\#(requested)}"#))
        await fake.push(JSONRPC.notification(#"{"seq":44,"agent_id":"a","ts":44,"kind":"approval.requested","payload":\#(requested)}"#))
        await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 45, text: "after")))
        try await eventually { model.thread(for: "a").lastMessageText == "after" }
        #expect(model.pendingApprovalCount(of: "a") == 1, "the same id twice is one approval")

        await fake.push(
            JSONRPC.notification(
                #"{"seq":46,"agent_id":"a","ts":46,"kind":"approval.resolved","payload":{"approval_id":"A","decision":"allow","by":"user","remember":false}}"#))
        await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 47, text: "done")))
        try await eventually { model.thread(for: "a").lastMessageText == "done" }
        #expect(model.pendingApprovalCount(of: "a") == 0)
        await model.disconnect()
    }
}
