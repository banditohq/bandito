import Foundation
import Testing

@testable import BanditoKit

/// The read marks between the devices of one owner: what a device sends to the daemon (`messages.read`) and when, what
/// a mark from another device does here (`read_mark`, `read_seq`), and what an older daemon does with the sending.
@MainActor
@Suite struct ReadMarkSyncTests {
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
        let name = "test.readsync.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A server whose sends are recorded instead of going to a daemon, with `interval` between two sends of one agent.
    private func server(interval: Duration = .milliseconds(150), marks: ReadMarks? = nil) -> (ServerModel, SendLog) {
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let server = ServerModel(
            config: config,
            readMarks: marks ?? ReadMarks(serverID: config.id, defaults: freshDefaults()))
        let log = SendLog()
        server.threads.readSync.interval = interval
        server.threads.readSync.send = { id, seq in log.sent.append(SendLog.Sent(agent: id, seq: seq, at: ContinuousClock.now)) }
        return (server, log)
    }

    /// Waits until `condition` holds, for at most two seconds.
    /// Waits for the condition for up to 10 s: a deadline, not a count of sleeps, so a slow runner or a neighbouring
    /// test that holds the main actor only makes the wait longer.
    private func settle(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aMovedReadIsSentOnceWithItsSeq() async {
        let (server, log) = server()
        server.threads[agent] = thread([
            event(1, .messageUser(text: "hi", source: .user, fromAgent: nil)),
            event(2, .messageAssistant(text: "one")),
        ])
        server.apply(event(3, .messageAssistant(text: "reply")))
        let box = server.threadSummary(for: agent)
        #expect(box.unreadCount == 1)
        box.markRead()
        #expect(box.unreadCount == 0)
        await settle { !log.sent.isEmpty }
        #expect(log.sent.map(\.seq) == [3])
        #expect(log.sent.first?.agent == agent)
    }

    @Test func aMarkThatDidNotMoveIsNotSent() async {
        let (server, log) = server()
        server.threads[agent] = thread([event(1, .messageAssistant(text: "one"))])
        let box = server.threadSummary(for: agent)
        box.markRead()
        box.markRead()
        // A thread that is not loaded has nothing to mark either.
        server.threadSummary(for: "not-loaded").markRead()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(log.sent.isEmpty)
    }

    @Test func sendsOfOneAgentAreAtLeastAnIntervalApartAndTheLastValueWins() async {
        let interval = Duration.milliseconds(1500)
        let (server, log) = server(interval: interval)
        server.threads[agent] = thread([event(1, .messageAssistant(text: "one"))])
        let box = server.threadSummary(for: agent)
        server.apply(event(2, .messageAssistant(text: "two")))
        box.markRead()
        await settle { !log.sent.isEmpty }
        // Three more replies, read in one run of the main actor with no suspension between them, so all three land in
        // one interval however the runner is loaded. The send that follows carries the newest seq.
        server.apply(event(3, .messageAssistant(text: "more")))
        box.markRead()
        server.apply(event(4, .messageAssistant(text: "more")))
        box.markRead()
        server.apply(event(5, .messageAssistant(text: "more")))
        box.markRead()
        await settle { log.sent.count >= 2 }
        #expect(log.sent.map(\.seq) == [2, 5], "the first at once, then the newest one interval later")
        if log.sent.count == 2 {
            let gap = log.sent[1].at - log.sent[0].at
            // The send's instant is read inside the send, a few microseconds after the code stamped its start.
            #expect(gap >= interval - .milliseconds(5), "two sends of one agent are not closer than the interval")
        }
    }

    @Test func aRemoteReadSettlesUnreadAndSendsNothingBack() async {
        let (server, log) = server()
        server.threads[agent] = thread([
            event(1, .messageUser(text: "hi", source: .user, fromAgent: nil)),
            event(2, .messageAssistant(text: "one")),
        ])
        server.apply(event(3, .messageAssistant(text: "reply")))
        let box = server.threadSummary(for: agent)
        #expect(box.unreadCount == 1)
        // The read mark of another device: a transient event, seq 0.
        server.apply(Event(seq: 0, agentId: agent, ts: 1, body: .readMark(seq: 3)))
        #expect(box.unreadCount == 0)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(log.sent.isEmpty, "a mark from the daemon is not sent back")
    }

    @Test func aRemoteMarkNeverMovesBackAndIsKeptAsItCame() {
        // A device that read nothing yet: its mark is 0, so the three replies are unread until a mark says otherwise.
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let marks = ReadMarks(serverID: config.id, defaults: freshDefaults())
        marks.set(0, for: agent)
        let server = ServerModel(config: config, readMarks: marks)
        server.threads[agent] = thread([
            event(1, .messageAssistant(text: "one")),
            event(2, .messageAssistant(text: "two")),
            event(3, .messageAssistant(text: "three")),
        ])
        let box = server.threadSummary(for: agent)
        #expect(box.unreadCount == 3)
        server.apply(Event(seq: 0, agentId: agent, ts: 1, body: .readMark(seq: 2)))
        #expect(box.unreadCount == 1)
        server.apply(Event(seq: 0, agentId: agent, ts: 2, body: .readMark(seq: 1)))
        #expect(box.unreadCount == 1, "an older mark does not move the read point back")
        #expect(marks.seq(for: agent) == 2)
        // The daemon cut the mark already: a mark past this device's thread is kept as it came.
        server.apply(Event(seq: 0, agentId: agent, ts: 3, body: .readMark(seq: 999)))
        #expect(box.unreadCount == 0)
        #expect(marks.seq(for: agent) == 999)
    }

    @Test func aRemoteMarkForAThreadNotLoadedYetIsKept() {
        let defaults = freshDefaults()
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let marks = ReadMarks(serverID: config.id, defaults: defaults)
        let server = ServerModel(config: config, readMarks: marks)
        server.apply(Event(seq: 0, agentId: agent, ts: 1, body: .readMark(seq: 7)))
        #expect(marks.seq(for: agent) == 7)
        server.threads[agent] = thread((1...9).map { event(Int64($0), .messageAssistant(text: "m\($0)")) })
        #expect(server.threadSummary(for: agent).unreadCount == 2, "replies 8 and 9 are unread")
    }

    @Test func theReadSeqOfTheAgentListAppliesLikeAMark() throws {
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let marks = ReadMarks(serverID: config.id, defaults: freshDefaults())
        marks.set(0, for: agent)
        let server = ServerModel(config: config, readMarks: marks)
        // The list comes before the chat is opened (the usual order): the mark is kept for the chat.
        let list = """
            [{"id":"forge","name":"Forge","runtime":"claude","cwd":"/tmp","read_seq":2},\
            {"id":"later","name":"Later","runtime":"claude","cwd":"/tmp","read_seq":1},\
            {"id":"fresh","name":"Fresh","runtime":"claude","cwd":"/tmp"}]
            """
        let agents = try RPCClient.decoder.decode([Agent].self, from: Data(list.utf8))
        #expect(agents.map(\.readSeq) == [2, 1, nil])
        server.applyReadSeqs(agents)
        #expect(marks.seq(for: agent) == 2)
        #expect(marks.seq(for: "fresh") == nil, "no mark from the daemon, nothing stored")
        server.threads[agent] = thread((1...3).map { event(Int64($0), .messageAssistant(text: "m\($0)")) })
        #expect(server.threadSummary(for: agent).unreadCount == 1)
        server.threads["later"] = thread((1...3).map { event(Int64($0), .messageAssistant(text: "m\($0)")) })
        #expect(server.threadSummary(for: "later").unreadCount == 2)
        // A list that repeats an older mark does not move it back.
        server.applyReadSeqs(agents)
        #expect(server.threadSummary(for: agent).unreadCount == 1)
    }

    @Test func aDaemonWithoutTheMethodStopsTheSendingUntilReconnect() async {
        let (server, log) = server(interval: .milliseconds(20))
        server.threads.readSync.send = { id, seq in
            log.sent.append(SendLog.Sent(agent: id, seq: seq, at: ContinuousClock.now))
            throw RPCError(code: RPCError.methodNotFound, message: "unknown method messages.read")
        }
        server.threads[agent] = thread([event(1, .messageAssistant(text: "one"))])
        let box = server.threadSummary(for: agent)
        server.apply(event(2, .messageAssistant(text: "two")))
        box.markRead()
        await settle { log.sent.count == 1 }
        // Silently off: a later read is not sent to this server, and the reader is not told anything.
        server.apply(event(3, .messageAssistant(text: "three")))
        box.markRead()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(log.sent.count == 1)
        #expect(box.unreadCount == 0, "the local read still happens")
        // A reconnect starts sending again.
        server.threads.readSync.resume()
        server.apply(event(4, .messageAssistant(text: "four")))
        box.markRead()
        await settle { log.sent.count == 2 }
        #expect(log.sent.map(\.seq) == [2, 4])
    }

    @Test func aLostSendIsSentAgainWithTheNextRead() async {
        let (server, log) = server(interval: .milliseconds(20))
        var failNext = true
        server.threads.readSync.send = { id, seq in
            log.sent.append(SendLog.Sent(agent: id, seq: seq, at: ContinuousClock.now))
            if failNext {
                failNext = false
                throw RPCError(code: -32000, message: "offline")
            }
        }
        server.threads[agent] = thread([event(1, .messageAssistant(text: "one"))])
        let box = server.threadSummary(for: agent)
        server.apply(event(2, .messageAssistant(text: "two")))
        box.markRead()
        await settle { log.sent.count == 1 }
        server.apply(event(3, .messageAssistant(text: "three")))
        box.markRead()
        await settle { log.sent.count == 2 }
        #expect(log.sent.map(\.seq) == [2, 3])
    }
}

/// The sends a test server made, in order.
@MainActor
private final class SendLog {
    struct Sent {
        let agent: String
        let seq: Int64
        let at: ContinuousClock.Instant
    }

    var sent: [Sent] = []
}

extension ReadMarkSyncTests {
    @Test func aSendThatFailsWaitsForTheNextConnection() async {
        let (server, log) = server(interval: .milliseconds(20))
        var online = false
        server.threads.readSync.send = { id, seq in
            log.sent.append(SendLog.Sent(agent: id, seq: seq, at: ContinuousClock.now))
            if !online { throw URLError(.notConnectedToInternet) }
        }
        server.threads[agent] = thread([event(1, .messageAssistant(text: "one"))])
        let box = server.threadSummary(for: agent)
        server.apply(event(2, .messageAssistant(text: "two")))
        box.markRead()
        await settle { log.sent.count == 1 }
        // Offline: the mark is not dropped, and it is not retried on a timer either.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(log.sent.map(\.seq) == [2])
        #expect(box.unreadCount == 0, "the local read still happens")
        // The connection comes back: the mark that was not sent goes out.
        online = true
        server.threads.readSync.resume()
        await settle { log.sent.count == 2 }
        #expect(log.sent.map(\.seq) == [2, 2])
    }

    @Test func aNewerReadReplacesTheUnsentOne() async {
        let (server, log) = server(interval: .milliseconds(20))
        var online = false
        server.threads.readSync.send = { id, seq in
            log.sent.append(SendLog.Sent(agent: id, seq: seq, at: ContinuousClock.now))
            if !online { throw URLError(.notConnectedToInternet) }
        }
        server.threads[agent] = thread([event(1, .messageAssistant(text: "one"))])
        let box = server.threadSummary(for: agent)
        server.apply(event(2, .messageAssistant(text: "two")))
        box.markRead()
        await settle { log.sent.count == 1 }
        server.apply(event(3, .messageAssistant(text: "three")))
        box.markRead()
        await settle { log.sent.count == 2 }
        online = true
        server.threads.readSync.resume()
        await settle { log.sent.count == 3 }
        #expect(log.sent.map(\.seq) == [2, 3, 3], "the unsent mark is the newest one")
    }

    @Test func aLocalMarkAboveTheDaemonsIsSentWhenTheListArrives() async {
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let localMarks = ReadMarks(serverID: config.id, defaults: freshDefaults())
        localMarks.set(5, for: agent)  // read offline: the daemon does not have 5
        localMarks.set(2, for: "ahead")  // the daemon is ahead of this device
        localMarks.set(4, for: "level")  // the daemon has the same mark
        let server = ServerModel(config: config, readMarks: localMarks)
        let log = SendLog()
        server.threads.readSync.interval = .milliseconds(20)
        server.threads.readSync.send = { id, seq in
            log.sent.append(SendLog.Sent(agent: id, seq: seq, at: ContinuousClock.now))
        }
        let list = """
            [{"id":"forge","name":"Forge","runtime":"claude","cwd":"/tmp","read_seq":2},\
            {"id":"ahead","name":"Ahead","runtime":"claude","cwd":"/tmp","read_seq":7},\
            {"id":"level","name":"Level","runtime":"claude","cwd":"/tmp","read_seq":4},\
            {"id":"fresh","name":"Fresh","runtime":"claude","cwd":"/tmp"}]
            """
        let agents = try! RPCClient.decoder.decode([Agent].self, from: Data(list.utf8))
        server.applyReadSeqs(agents)
        await settle { !log.sent.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.sent.map(\.agent) == [agent], "only this device's mark above the daemon's goes out")
        #expect(log.sent.map(\.seq) == [5])
        // The daemon's higher mark is applied here, and it is not sent back.
        #expect(localMarks.seq(for: "ahead") == 7)
        #expect(log.sent.count == 1)
    }

    @Test func theDaemonsMarkOfAMovedChatIsTold() {
        let config = ServerConfig(name: "t", endpoint: .local(socketPath: "/tmp/none"))
        let marks = ReadMarks(serverID: config.id, defaults: freshDefaults())
        marks.set(0, for: agent)
        let server = ServerModel(config: config, readMarks: marks)
        var moves: [(String, Int64)] = []
        server.onRemoteRead = { agentID, seq in moves.append((agentID, seq)) }
        server.threads[agent] = thread([
            event(1, .messageAssistant(text: "one")),
            event(2, .messageAssistant(text: "two")),
        ])
        server.apply(Event(seq: 0, agentId: agent, ts: 1, body: .readMark(seq: 2)))
        server.apply(Event(seq: 0, agentId: agent, ts: 2, body: .readMark(seq: 2)))
        server.apply(Event(seq: 0, agentId: agent, ts: 3, body: .readMark(seq: 1)))
        #expect(moves.count == 1, "only a move is told")
        #expect(moves.first?.0 == agent)
        #expect(moves.first?.1 == 2, "with the seq it moved to")
        // The answer to this device's own read is a move too.
        server.receivedReadMark(agentID: agent, seq: 9)
        #expect(moves.last?.1 == 9)
    }
}

/// The wire of the read mark: decoded with the app's decoder, and a kind the app does not know never breaks a page.
@Suite struct ReadMarkEventWireTests {
    @Test func readMarkDecodesAsATransientEvent() throws {
        let e = try RPCClient.decoder.decode(
            Event.self, from: Data(#"{"seq":0,"agent_id":"a1","ts":1,"kind":"read_mark","payload":{"seq":42}}"#.utf8))
        #expect(e.seq == 0)
        #expect(e.agentId == "a1")
        #expect(e.body == .readMark(seq: 42))
    }

    @Test func anUnknownKindDoesNotBreakAPageOfEvents() throws {
        let json = """
            [{"seq":5,"agent_id":"a1","ts":1,"kind":"message.assistant","payload":{"text":"one"}},\
            {"seq":6,"agent_id":"a1","ts":2,"kind":"future.thing","payload":{"x":[1,2,{"y":null}]}},\
            {"seq":0,"agent_id":"a1","ts":3,"kind":"read_mark","payload":{"seq":5}},\
            {"seq":7,"agent_id":"a1","ts":4,"kind":"message.assistant","payload":{"text":"two"}}]
            """
        let events = try RPCClient.decoder.decode([Event].self, from: Data(json.utf8))
        #expect(events.count == 4)
        #expect(events[1].body == .unknown(kind: "future.thing"))
        #expect(events[2].body == .readMark(seq: 5))
        #expect(events[3].seq == 7)
    }
}
