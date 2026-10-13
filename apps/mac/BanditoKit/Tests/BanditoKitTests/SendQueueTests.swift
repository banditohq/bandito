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
        queue.interrupted(one.id, now: 0)
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

    // MARK: backoff, limits, uncertainty

    @Test func theBackoffDoublesAndStopsAtAMinute() {
        #expect((1...8).map { SendBackoff.delay(attempt: $0) } == [2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000, 60_000])
        #expect(SendBackoff.rateLimited(attempt: 1, retryAfter: nil) == 2_000)
        #expect(SendBackoff.rateLimited(attempt: 1, retryAfter: 30_000) == 30_000)
        #expect(SendBackoff.rateLimited(attempt: 1, retryAfter: 600_000) == 60_000)
    }

    @Test func aMessageThatKeepsDroppingIsGivenUpAfterFiveTries() {
        var queue = SendQueue()
        let one = item("again")
        queue.enqueue(one)
        var now: Int64 = 1_000
        var waits: [Int64] = []
        for _ in 0..<(SendBackoff.maxAttempts - 1) {
            queue.begin(one.id, baseline: 0)
            queue.interrupted(one.id, now: now)
            let waiting = queue.items[0]
            #expect(waiting.state == .waiting)
            waits.append((waiting.retryAt ?? 0) - now)
            now = waiting.retryAt ?? now
        }
        #expect(waits == [2_000, 4_000, 8_000, 16_000])
        queue.begin(one.id, baseline: 0)
        queue.interrupted(one.id, now: now)
        #expect(queue.items[0].state == .failed)
        #expect(queue.items[0].failureKind == .gaveUp)
        queue.retry(one.id)
        #expect(queue.items[0].attempts == 0 && queue.items[0].retryAt == nil && queue.items[0].state == .waiting)
    }

    @Test func aWaitingMessageIsNotOfferedBeforeItsTime() {
        var queue = SendQueue()
        let one = item("later")
        queue.enqueue(one)
        queue.begin(one.id, baseline: 0)
        queue.limited(one.id, now: 10_000, retryAfter: nil)
        #expect(queue.items[0].retryAt == 12_000)
        #expect(queue.next(serverID: server, agentID: "a1", now: 11_000) == nil)
        #expect(queue.delay(serverID: server, agentID: "a1", now: 11_000) == 1_000)
        #expect(queue.next(serverID: server, agentID: "a1", now: 12_000)?.id == one.id)
        #expect(!queue.items[0].maybeDelivered)
    }

    @Test func aKeyThatIsNotAcceptedFailsAtOnceWithItsKind() {
        var queue = SendQueue()
        let one = item("x")
        queue.enqueue(one)
        queue.begin(one.id, baseline: 0)
        queue.refused(one.id, reason: nil, kind: .key)
        #expect(queue.items[0].state == .failed && queue.items[0].failureKind == .key)
        #expect(queue.next(serverID: server, agentID: "a1") == nil)
    }

    @Test func anUncertainMessageBlocksTheOnesAfterItUntilThePersonDecides() {
        var queue = SendQueue()
        let first = item("one"), second = item("two")
        queue.enqueue(first)
        queue.enqueue(second)
        queue.begin(first.id, baseline: 0)
        queue.uncertain(first.id)
        #expect(queue.next(serverID: server, agentID: "a1") == nil)
        queue.retry(first.id)
        #expect(queue.next(serverID: server, agentID: "a1")?.id == first.id)
        queue.uncertain(first.id)
        queue.remove(first.id)
        #expect(queue.next(serverID: server, agentID: "a1")?.id == second.id)
    }

    @Test func aMessageWithTheSameTextWaitsForTheEchoOfThePreviousOne() {
        var queue = SendQueue()
        let first = item("ok"), second = item("ok"), other = item("different")
        queue.enqueue(first)
        queue.enqueue(second)
        queue.begin(first.id, baseline: 0)
        queue.sent(first.id)
        #expect(queue.next(serverID: server, agentID: "a1") == nil)
        queue.remove(first.id)
        #expect(queue.next(serverID: server, agentID: "a1")?.id == second.id)
        var other2 = SendQueue()
        other2.enqueue(first)
        other2.enqueue(other)
        other2.begin(first.id, baseline: 0)
        other2.sent(first.id)
        #expect(other2.next(serverID: server, agentID: "a1")?.id == other.id)
    }

    @Test func aFileWrittenBeforeAttemptsExistedStillReads() throws {
        let id = UUID()
        let json = """
            {"items":[{"id":"a","serverID":"\(id.uuidString)","agentID":"a1","text":"old","attachments":[],"viaButton":false,"createdAt":1,"state":"waiting","baseline":0,"maybeDelivered":false}]}
            """
        let queue = try JSONDecoder().decode(SendQueue.self, from: Data(json.utf8))
        #expect(queue.items[0].attempts == 0 && queue.items[0].retryAt == nil && queue.items[0].failureKind == nil)
    }

    @Test func theFileIsLeftOutOfBackups() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sendqueue-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var queue = SendQueue()
        queue.enqueue(item("private words"))
        SendQueueFile(url: url).save(queue)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func anUncertainOrGivenUpMessageIsLetGoWhenItsEchoShowsLater() {
        var uncertain = item("maybe")
        uncertain.state = .uncertain
        uncertain.baseline = 0
        var gaveUp = item("tired")
        gaveUp.state = .failed
        gaveUp.failureKind = .gaveUp
        var refused = item("refused")
        refused.state = .failed
        refused.failureKind = .refused
        let thread = [userItem("maybe", id: "s1"), userItem("tired", id: "s2"), userItem("refused", id: "s3")]
        #expect(SendQueue.hasEcho(uncertain, in: thread))
        #expect(SendQueue.hasEcho(gaveUp, in: thread))
        // A refusal is not "maybe delivered": the daemon said no.
        #expect(!SendQueue.hasEcho(refused, in: thread))
        #expect(!SendQueue.hasEcho(uncertain, in: []))
    }

    @Test func aManualRetryOfAnUncertainOrGivenUpMessageReadsTheThreadFirst() {
        var queue = SendQueue()
        let one = item("x"), two = item("y")
        queue.enqueue(one)
        queue.enqueue(two)
        queue.begin(one.id, baseline: 0)
        queue.uncertain(one.id)
        queue.retry(one.id)
        #expect(queue.items[0].state == .waiting && queue.items[0].maybeDelivered)
        queue.begin(two.id, baseline: 0)
        queue.refused(two.id, reason: "no")
        queue.retry(two.id)
        #expect(!queue.items[1].maybeDelivered)
    }
}
