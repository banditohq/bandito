import AVFoundation
import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// What the person wrote without a connection: it waits, goes out in order, once, when the connection is there; and what
/// the outbox does when a send does not go through (no sleeping: the clock and the network are injected).
@MainActor
@Suite(.serialized) struct ChatOutboxTests {
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [DemoClientCall] = []
        var sends: [String] { lock.withLock { list.filter { $0.method == "agents.send" }.compactMap(\.text) } }
        func add(_ call: DemoClientCall) { lock.withLock { list.append(call) } }
    }

    /// A clock that moves when the outbox sleeps, and a network that fails as the test says.
    final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Int64 = 1_000_000
        private var _sleeps: [Int64] = []
        private var _sent: [String] = []
        /// Errors for the sends, in order; a send after them goes through.
        var failures: [Error] = []
        /// Sleeps at least this long wait until `release()` (the echo timeout must not run out by itself).
        var holdLongSleeps = false
        private var gate: CheckedContinuation<Void, Never>?
        var reads: [QueuedSend] = []
        /// What `readThread` does: set by the test.
        var onRead: (@MainActor (ServerModel, QueuedSend) -> Bool)?
        var onSend: (@MainActor (ServerModel, QueuedSend) -> Void)?

        var now: Int64 { lock.withLock { _now } }
        var sleeps: [Int64] { lock.withLock { _sleeps } }
        var sent: [String] { lock.withLock { _sent } }

        func sleep(_ duration: Duration) async {
            let ms = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
            if holdLongSleeps, ms >= 5_000 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.withLock { gate = continuation }
                }
                return
            }
            lock.withLock {
                _sleeps.append(ms)
                _now += ms
            }
        }

        @MainActor var hooks: ChatOutboxHooks {
            ChatOutboxHooks(
                now: { [self] in now },
                sleep: { [self] in await sleep($0) },
                send: { [self] server, item in
                    lock.withLock { _sent.append(item.text) }
                    let failure: Error? = lock.withLock { failures.isEmpty ? nil : failures.removeFirst() }
                    if let failure { throw failure }
                    onSend?(server, item)
                },
                readThread: { [self] server, item in
                    lock.withLock { reads.append(item) }
                    return onRead?(server, item) ?? true
                })
        }
    }

    func offlineServer() async -> (ServerModel, Heard) {
        let (server, transport) = DemoDaemon.server(
            id: UUID(), name: "Offline", setup: DemoDaemonSetup(agentIDs: ["a1"], hostname: "demo"))
        let heard = Heard()
        await transport.setClientHook { call in heard.add(call) }
        return (server, heard)
    }

    func connected(_ outbox: ChatOutbox? = nil, harness: Harness) async -> (ServerModel, ChatOutbox) {
        let (server, _) = await offlineServer()
        await server.connect()
        let outbox = outbox ?? ChatOutbox(file: nil, hooks: harness.hooks)
        outbox.attach([server])
        return (server, outbox)
    }

    func waitUntil(_ limit: Int = 600, _ done: () -> Bool) async {
        var waited = 0
        while !done(), waited < limit {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
    }

    func echo(_ server: ServerModel, _ text: String, seq: Int64) {
        server.apply(
            Event(
                seq: seq, agentId: "a1", ts: 1, body: .messageUser(
                    text: text, source: .user, fromAgent: nil, replyTo: nil, attachments: [], queued: false, mentions: [],
                    viaButton: false, schedule: nil)))
    }

    // MARK: waiting for a connection

    @Test func messagesWrittenOfflineWaitAndGoOutInOrderOnceWhenTheConnectionComes() async {
        let (server, heard) = await offlineServer()
        let outbox = ChatOutbox(file: nil)
        outbox.attach([server])
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "one")
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "two")
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "three")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(heard.sends.isEmpty)
        #expect(outbox.items(serverID: server.id, agentID: "a1").map(\.state) == [.waiting, .waiting, .waiting])

        await server.connect()
        await waitUntil { heard.sends.count >= 3 }
        #expect(heard.sends == ["one", "two", "three"])
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").isEmpty }
        #expect(outbox.items(serverID: server.id, agentID: "a1").isEmpty)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(heard.sends == ["one", "two", "three"])
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

    @Test func aServerMadeAgainWithTheSameIdIsWatchedAgain() async {
        let harness = Harness()
        let id = UUID()
        let (first, _) = DemoDaemon.server(id: id, name: "A", setup: DemoDaemonSetup(agentIDs: ["a1"]))
        let (second, _) = DemoDaemon.server(id: id, name: "B", setup: DemoDaemonSetup(agentIDs: ["a1"]))
        let outbox = ChatOutbox(file: nil, hooks: harness.hooks)
        outbox.attach([first])
        outbox.enqueue(serverID: id, agentID: "a1", text: "hello")
        // The model is replaced (the server was edited and made again); the old one never connects.
        outbox.attach([second])
        await second.connect()
        await waitUntil { !harness.sent.isEmpty }
        #expect(harness.sent == ["hello"])
    }

    // MARK: failures

    @Test func aRefusedKeyFailsAtOnceAndIsNotRetried() async {
        for (error, kind) in [
            (RPCError(code: RPCError.keyRejected, message: "no"), QueuedSend.Failure.key),
            (RPCError(code: RPCError.unauthorized, message: "no"), .key),
            (RPCError(code: RPCError.insecureTransport, message: "no"), .insecure),
        ] {
            let harness = Harness()
            harness.failures = [error]
            let (server, outbox) = await connected(harness: harness)
            outbox.enqueue(serverID: server.id, agentID: "a1", text: "secret")
            await waitUntil { outbox.items(serverID: server.id, agentID: "a1").first?.state == .failed }
            let item = outbox.items(serverID: server.id, agentID: "a1").first
            #expect(item?.state == .failed && item?.failureKind == kind)
            #expect(harness.sent == ["secret"], "one try only")
            #expect(harness.sleeps.isEmpty)
            // The person's retry sends it again.
            outbox.retry(item?.id ?? "")
            await waitUntil { outbox.items(serverID: server.id, agentID: "a1").first?.state == .sent }
            #expect(harness.sent == ["secret", "secret"])
        }
    }

    @Test func aRateLimitWaitsTheBackoffOrTheServersWord() async {
        let harness = Harness()
        harness.failures = [
            RPCError(code: RPCError.rateLimited, message: "slow down"),
            RPCError(code: RPCError.rateLimited, message: "slow down", data: .object(["retry_after": .number(30)])),
        ]
        let (server, outbox) = await connected(harness: harness)
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "later")
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").first?.state == .sent }
        #expect(harness.sent == ["later", "later", "later"])
        #expect(Array(harness.sleeps.prefix(2)) == [2_000, 30_000])
        // A rate limit is a refusal: the thread was not read to see whether it had arrived.
        #expect(harness.reads.isEmpty)
    }

    @Test func aSendThatKeepsDroppingIsGivenUpAfterFiveTriesWithGrowingWaits() async {
        let harness = Harness()
        harness.failures = (0..<10).map { _ in RPCError(code: RPCError.disconnected, message: "closed") }
        let (server, outbox) = await connected(harness: harness)
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "never")
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").first?.state == .failed }
        let item = outbox.items(serverID: server.id, agentID: "a1").first
        #expect(item?.failureKind == .gaveUp)
        #expect(harness.sent.count == SendBackoff.maxAttempts)
        #expect(harness.sleeps == [2_000, 4_000, 8_000, 16_000])
    }

    @Test func anEchoThatComesLateIsNotSentAgain() async {
        let harness = Harness()
        harness.failures = [RPCError(code: RPCError.disconnected, message: "closed")]
        let (server, outbox) = await connected(harness: harness)
        // The thread is read from the daemon before anything is judged; the daemon had the message (its event comes with
        // that reading, long after any timer would have decided).
        harness.onRead = { server, _ in
            self.echo(server, "once only", seq: 50)
            return true
        }
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "once only")
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").isEmpty }
        #expect(harness.reads.count == 1)
        #expect(harness.sent == ["once only"], "no second copy")
        #expect(outbox.items(serverID: server.id, agentID: "a1").isEmpty)
    }

    @Test func aThreadThatCannotBeReadLeavesTheDecisionToThePerson() async {
        let harness = Harness()
        harness.failures = [RPCError(code: RPCError.timedOut, message: "slow")]
        let (server, outbox) = await connected(harness: harness)
        harness.onRead = { _, _ in false }
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "unsure")
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").first?.state == .uncertain }
        #expect(outbox.items(serverID: server.id, agentID: "a1").first?.state == .uncertain)
        #expect(harness.sent == ["unsure"], "not sent again")
        // "Send again" is the person's word.
        harness.onRead = nil
        outbox.retry(outbox.items(serverID: server.id, agentID: "a1")[0].id)
        await waitUntil { harness.sent.count == 2 }
        #expect(harness.sent == ["unsure", "unsure"])
    }

    @Test func aGivenUpMessageThatTheThreadHasIsNotSentAgainByTheRetry() async {
        let harness = Harness()
        harness.failures = (0..<10).map { _ in RPCError(code: RPCError.disconnected, message: "closed") }
        let (server, outbox) = await connected(harness: harness)
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "it came")
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").first?.state == .failed }
        let sends = harness.sent.count
        // The daemon had it after all: its event shows up when the person looks.
        echo(server, "it came", seq: 70)
        outbox.releaseEchoes(serverID: server.id, agentID: "a1", thread: server.thread(for: "a1"))
        #expect(outbox.items(serverID: server.id, agentID: "a1").isEmpty, "let go as delivered")
        // And one that is still there when the person presses "Send again": the thread is read first.
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "late echo")
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").first?.state == .failed }
        let after = harness.sent.count
        harness.failures = []
        harness.onRead = { server, _ in
            self.echo(server, "late echo", seq: 71)
            return true
        }
        outbox.retry(outbox.items(serverID: server.id, agentID: "a1")[0].id)
        await waitUntil { outbox.items(serverID: server.id, agentID: "a1").isEmpty }
        #expect(sends >= SendBackoff.maxAttempts)
        #expect(harness.sent.count == after, "not sent again")
        #expect(harness.reads.count >= 1)
    }

    @Test func aMessageWithTheSameTextWaitsForTheEchoOfTheOneBefore() async {
        let harness = Harness()
        harness.holdLongSleeps = true
        let (server, outbox) = await connected(harness: harness)
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "ok")
        outbox.enqueue(serverID: server.id, agentID: "a1", text: "ok")
        await waitUntil { !harness.sent.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.sent == ["ok"], "the second waits for the first's event")
        // The first's event comes; the chat lets it go; the second leaves, and its bubble is still there until its own.
        echo(server, "ok", seq: 60)
        outbox.releaseEchoes(serverID: server.id, agentID: "a1", thread: server.thread(for: "a1"))
        await waitUntil { harness.sent.count == 2 }
        #expect(harness.sent == ["ok", "ok"])
        #expect(outbox.items(serverID: server.id, agentID: "a1").count == 1)
    }

    // MARK: how an error is read

    @Test func errorsAreReadAsTheyAre() {
        #expect(ChatSendOutcome.classify(RPCError(code: RPCError.disconnected, message: "")) == .lost)
        #expect(ChatSendOutcome.classify(RPCError(code: RPCError.timedOut, message: "")) == .lost)
        #expect(ChatSendOutcome.classify(URLError(.networkConnectionLost)) == .lost)
        #expect(ChatSendOutcome.classify(RPCError(code: RPCError.keyRejected, message: "")) == .notAllowed(.key))
        #expect(ChatSendOutcome.classify(RPCError(code: RPCError.insecureTransport, message: "")) == .notAllowed(.insecure))
        #expect(ChatSendOutcome.classify(RPCError(code: RPCError.rateLimited, message: "")) == .rateLimited(retryAfter: nil))
        #expect(
            ChatSendOutcome.classify(RPCError(code: RPCError.rateLimited, message: "", data: .object(["retry_after": .number(12)])))
                == .rateLimited(retryAfter: 12_000))
        #expect(ChatSendOutcome.classify(RPCError(code: RPCError.invalidParams, message: "bad")) == .refused("bad"))
    }

    // MARK: files and camera

    @Test func aFileThePickerCopiedIsReadOnceAndRemoved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        #expect(ChatTempFiles.readAndRemove(url) == Data("hello".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(ChatTempFiles.readAndRemove(url) == nil)
    }

    @Test func theCameraIsAskedForOnlyWhenThatIsStillOpen() {
        #expect(ChatCameraAccess.decision(for: .authorized) == .open)
        #expect(ChatCameraAccess.decision(for: .notDetermined) == .ask)
        #expect(ChatCameraAccess.decision(for: .denied) == .explain)
        #expect(ChatCameraAccess.decision(for: .restricted) == .explain)
    }
}
