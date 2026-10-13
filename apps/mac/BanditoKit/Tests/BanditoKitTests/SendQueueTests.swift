import Foundation
import Testing

@testable import BanditoKit

/// Messages written without a connection: order, retry, and no copy when the link drops mid-send.
@Suite struct SendQueueTests {
    let server = UUID()

    func item(_ text: String, agent: String = "a1", at: Int64 = 1) -> QueuedSend {
        QueuedSend(serverID: server, agentID: agent, text: text, createdAt: at)
    }

    func userItem(_ text: String, id: String = "s1") -> ThreadItem {
        .user(id: id, text: text, source: .user, from: nil, ts: 1)
    }

    @Test func messagesLeaveOneAtATimeInTheOrderTheyWereWritten() {
        var queue = SendQueue()
        let first = item("one"), second = item("two"), other = item("elsewhere", agent: "a2")
        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(other)
        #expect(queue.next(serverID: server, agentID: "a1")?.id == first.id)
        queue.begin(first.id, baseline: 0)
        // The first is out: the second waits, another agent's message does not.
        #expect(queue.next(serverID: server, agentID: "a1") == nil)
        #expect(queue.next(serverID: server, agentID: "a2")?.id == other.id)
        queue.sent(first.id)
        #expect(queue.next(serverID: server, agentID: "a1")?.id == second.id)
    }

    @Test func aRefusedMessageBlocksTheOnesAfterItUntilItIsRetried() {
        var queue = SendQueue()
        let first = item("one"), second = item("two")
        queue.enqueue(first)
        queue.enqueue(second)
        queue.begin(first.id, baseline: 0)
        queue.refused(first.id, reason: "too large")
        #expect(queue.next(serverID: server, agentID: "a1") == nil)
        queue.retry(first.id)
        #expect(queue.next(serverID: server, agentID: "a1")?.id == first.id)
        #expect(queue.items(serverID: server, agentID: "a1").first?.failure == nil)
    }

    @Test func aMessageIsQueuedOnceWhateverHowOftenItIsEnqueued() {
        var queue = SendQueue()
        let one = item("one")
        queue.enqueue(one)
        queue.enqueue(one)
        #expect(queue.items.count == 1)
    }

    @Test func aSendThatDroppedMidwayIsNotSentTwiceWhenTheDaemonHasIt() {
        var queue = SendQueue()
        let one = item("deploy it")
        queue.enqueue(one)
        queue.begin(one.id, baseline: 1)
        queue.interrupted(one.id)
        let waiting = queue.items[0]
        #expect(waiting.state == .waiting && waiting.maybeDelivered)
        // After the reconnect the thread shows a second message with this text: the daemon took it.
        let thread = [userItem("deploy it", id: "s1"), userItem("deploy it", id: "s2")]
        #expect(SendQueue.isDelivered(waiting, in: thread))
        // Still one: it never arrived, so it goes out again.
        #expect(!SendQueue.isDelivered(waiting, in: [userItem("deploy it")]))
    }

    @Test func aMessageWithTheSameTextAsAnOlderOneIsNotMistakenForIt() {
        let one = QueuedSend(serverID: server, agentID: "a1", text: "yes", createdAt: 1, baseline: 2)
        let old = [userItem("yes", id: "s1"), userItem("yes", id: "s2")]
        #expect(!SendQueue.isDelivered(one, in: old))
        #expect(SendQueue.isDelivered(one, in: old + [userItem("yes", id: "s3")]))
        // Another sender's words, or the agent's, do not count.
        let crew = ThreadItem.user(id: "s9", text: "yes", source: .crew, from: "Scout", ts: 1)
        #expect(!SendQueue.isDelivered(one, in: old + [crew]))
    }

    @Test func theEchoOfASentMessageReleasesItsPlace() {
        var queue = SendQueue()
        let one = item("hello")
        queue.enqueue(one)
        queue.begin(one.id, baseline: 0)
        queue.sent(one.id)
        #expect(!SendQueue.hasEcho(queue.items[0], in: []))
        #expect(SendQueue.hasEcho(queue.items[0], in: [userItem("hello")]))
    }

    @Test func aLaunchKeepsWhatWasWaitingAndDropsWhatWasAnswered() {
        var queue = SendQueue()
        let a = item("a"), b = item("b"), c = item("c")
        queue.enqueue(a)
        queue.enqueue(b)
        queue.enqueue(c)
        queue.begin(a.id, baseline: 0)
        queue.sent(a.id)
        queue.begin(b.id, baseline: 0)
        queue.restoredAfterLaunch()
        #expect(queue.items.map(\.text) == ["b", "c"])
        #expect(queue.items[0].maybeDelivered)
        #expect(queue.items[0].state == .waiting)
    }

    @Test func theQueueSurvivesTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sendqueue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = SendQueueFile(url: url)
        var queue = SendQueue()
        queue.enqueue(item("kept", at: 5))
        file.save(queue)
        #expect(file.load().items.map(\.text) == ["kept"])
        file.save(SendQueue())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(file.load().isEmpty)
    }
}
