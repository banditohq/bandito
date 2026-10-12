import Foundation
import Testing

@testable import BanditoKit

/// The unread count of an agent's chat: which rows are replies, where the read mark is kept, and how a thread's
/// count follows its events (a stream, a reply, the person's own message, a read).
@MainActor
@Suite struct UnreadRepliesTests {
    private let agent = "forge"

    private func event(_ seq: Int64, _ body: EventBody) -> Event {
        Event(seq: seq, agentId: agent, ts: 1_700_000_000_000 + seq, body: body)
    }

    private func thread(_ events: [Event]) -> AgentThread {
        var thread = AgentThread()
        for e in events { thread.apply(e) }
        return thread
    }

    private func freshDefaults() -> UserDefaults {
        let name = "test.unread.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func server(_ marks: ReadMarks) -> ServerModel {
        ServerModel(config: ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none")), readMarks: marks)
    }

    @Test func onlyFinishedRepliesHaveAReplySeq() {
        #expect(ThreadItem.assistant(id: "s5", text: "a", ts: 1).replySeq == 5)
        #expect(ThreadItem.assistant(id: "s5-s", text: "a", ts: 1).replySeq == 5)
        #expect(ThreadItem.assistant(id: "d-forge-7", text: "a", ts: 1).replySeq == nil)
        #expect(ThreadItem.user(id: "s3", text: "hi", source: .user, from: nil, ts: 1).replySeq == nil)
        #expect(ThreadItem.streaming(text: "wor").replySeq == nil)
        #expect(ThreadItem.note(id: "s9", text: "crew", kind: .crew, ts: 1).replySeq == nil)
    }

    @Test func countCountsOnlyRepliesAfterTheMark() {
        let items: [ThreadItem] = [
            .user(id: "s1", text: "hi", source: .user, from: nil, ts: 1),
            .assistant(id: "s2", text: "one", ts: 2),
            .user(id: "s3", text: "again", source: .user, from: nil, ts: 3),
            .assistant(id: "s4-s", text: "two", ts: 4),
            .streaming(text: "three"),
            .note(id: "s5", text: "crew", kind: .crew, ts: 5),
        ]
        #expect(UnreadReplies.count(in: items, readSeq: 0) == 2)
        #expect(UnreadReplies.count(in: items, readSeq: 1) == 2)
        #expect(UnreadReplies.count(in: items, readSeq: 2) == 1)
        #expect(UnreadReplies.count(in: items, readSeq: 4) == 0)
    }

    @Test func firstSightReadsEverythingLoaded() {
        #expect(UnreadReplies.firstSight(stored: nil, lastSeq: 42) == 42)
        #expect(UnreadReplies.firstSight(stored: 7, lastSeq: 42) == 7)
    }

    @Test func marksAreKeptPerServerAndAgent() {
        let defaults = freshDefaults()
        let first = UUID()
        ReadMarks(serverID: first, defaults: defaults).set(5, for: agent)
        #expect(ReadMarks(serverID: first, defaults: defaults).seq(for: agent) == 5)
        #expect(ReadMarks(serverID: first, defaults: defaults).seq(for: "other") == nil)
        #expect(ReadMarks(serverID: UUID(), defaults: defaults).seq(for: agent) == nil)
    }

    @Test func firstLaunchShowsNoBadgesForOldHistory() {
        let defaults = freshDefaults()
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let marks = ReadMarks(serverID: config.id, defaults: defaults)
        let server = ServerModel(config: config, readMarks: marks)
        server.threads[agent] = thread([
            event(1, .messageUser(text: "hi", source: .user, fromAgent: nil)),
            event(2, .messageAssistant(text: "one")),
            event(3, .messageAssistant(text: "two")),
        ])
        #expect(server.threadSummary(for: agent).unreadCount == 0)
        #expect(marks.seq(for: agent) == 3)
    }

    @Test func replyCountsUntilTheChatIsLookedAt() {
        let defaults = freshDefaults()
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let marks = ReadMarks(serverID: config.id, defaults: defaults)
        let server = server(marks)
        server.threads[agent] = thread([
            event(1, .messageUser(text: "hi", source: .user, fromAgent: nil)),
            event(2, .messageAssistant(text: "one")),
        ])
        let summary = server.threadSummary(for: agent)
        #expect(summary.unreadCount == 0)

        server.apply(event(3, .messageAssistant(text: "reply")))
        #expect(summary.unreadCount == 1)

        summary.markRead()
        #expect(summary.unreadCount == 0)
        #expect(marks.seq(for: agent) == 3)
    }

    @Test func aStreamCountsOnceItIsFinished() {
        let server = server(ReadMarks(serverID: UUID(), defaults: freshDefaults()))
        server.threads[agent] = thread([event(1, .messageAssistant(text: "old"))])
        let summary = server.threadSummary(for: agent)

        server.apply(event(0, .messageDelta(text: "Hello wor")))
        server.apply(event(0, .messageDelta(text: "ld")))
        #expect(summary.unreadCount == 0)

        server.apply(event(2, .messageAssistant(text: "Hello world")))
        #expect(summary.unreadCount == 1)
    }

    @Test func ownMessagesDoNotCount() {
        let server = server(ReadMarks(serverID: UUID(), defaults: freshDefaults()))
        server.threads[agent] = thread([event(1, .messageAssistant(text: "old"))])
        server.apply(event(2, .messageUser(text: "mine", source: .user, fromAgent: nil)))
        #expect(server.threadSummary(for: agent).unreadCount == 0)
    }

    @Test func theCountSurvivesARestart() {
        let defaults = freshDefaults()
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let first = ServerModel(config: config, readMarks: ReadMarks(serverID: config.id, defaults: defaults))
        first.threads[agent] = thread([event(1, .messageAssistant(text: "one"))])
        first.apply(event(2, .messageAssistant(text: "two")))
        #expect(first.threadSummary(for: agent).unreadCount == 1)

        let again = ServerModel(config: config, readMarks: ReadMarks(serverID: config.id, defaults: defaults))
        again.threads[agent] = thread([
            event(1, .messageAssistant(text: "one")),
            event(2, .messageAssistant(text: "two")),
        ])
        #expect(again.threadSummary(for: agent).unreadCount == 1)
    }
}
