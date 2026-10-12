import Foundation
import Testing

@testable import BanditoKit

/// A quiet turn (`nothing_to_report`, docs/ARCHITECTURE.md#quiet-turns): the text the agent writes in it is hidden, it
/// counts as no unread reply, and it leaves the preview as it was. A scheduled run's prompt carries its schedule.
@MainActor
@Suite struct QuietTurnTests {
    private let agent = "forge"

    private func event(_ seq: Int64, _ body: EventBody) -> Event {
        Event(seq: seq, agentId: agent, ts: 1_700_000_000_000 + seq, body: body)
    }

    private func decode(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    @Test func turnQuietAndTheScheduleOfARunDecodeFromTheWire() throws {
        let quiet = try decode(
            #"{"seq":9,"agent_id":"forge","ts":1,"kind":"turn.quiet","payload":{"turn_id":"t","reason":"no mail"}}"#)
        #expect(quiet.body == .turnQuiet(turnId: "t", reason: "no mail"))

        let run = try decode(
            #"{"seq":5,"agent_id":"forge","ts":1,"kind":"message.user","payload":{"text":"check the mail","source":"schedule","schedule":{"id":"s1","name":"","fired_at":42}}}"#)
        guard case .messageUser(let text, .schedule, _, _, _, _, _, _, let schedule) = run.body else {
            Issue.record("not a scheduled run: \(run.body)")
            return
        }
        #expect(text == "check the mail")
        #expect(schedule == ScheduleRun(id: "s1", name: "", firedAt: 42))

        let plain = try decode(#"{"seq":6,"agent_id":"forge","ts":1,"kind":"message.user","payload":{"text":"hi","source":"user"}}"#)
        #expect(plain.body == .messageUser(text: "hi", source: .user, fromAgent: nil))
    }

    @Test func aQuietTurnHidesItsTextAndCountsNoUnreadReply() {
        var thread = AgentThread()
        let events = [
            event(1, .turnStarted(turnId: "t1", source: .user)),
            event(2, .messageUser(text: "hi", source: .user, fromAgent: nil)),
            event(3, .messageAssistant(text: "answer")),
            event(4, .turnCompleted(turnId: "t1", status: .ok, usage: nil, costUsd: nil)),
            // A scheduled run that ends quietly, with a text the agent wrote anyway.
            event(5, .turnStarted(turnId: "t2", source: .schedule)),
            event(
                6,
                .messageUser(
                    text: "check the mail", source: .schedule, fromAgent: nil,
                    schedule: ScheduleRun(id: "s1", name: "Mail", firedAt: 6))),
            event(7, .turnQuiet(turnId: "t2", reason: "no mail")),
            event(8, .messageDelta(text: "Nothing")),
            event(9, .messageAssistant(text: "Nothing new")),
            event(10, .turnCompleted(turnId: "t2", status: .ok, usage: nil, costUsd: nil)),
        ]
        for e in events { thread.apply(e) }

        #expect(thread.quietTurn)
        let texts = thread.items.compactMap { item -> String? in
            if case .assistant(_, let text, _) = item { return text }
            return nil
        }
        #expect(texts == ["answer"])
        #expect(!thread.items.contains { if case .streaming = $0 { true } else { false } })
        // Only the answer of the first turn is a reply that can be unread.
        #expect(UnreadReplies.count(in: thread.items, readSeq: 0) == 1)
        #expect(UnreadReplies.count(in: thread.items, readSeq: 3) == 0)

        // The next turn is an ordinary one: its text shows, and the quiet mark is gone.
        thread.apply(event(11, .turnStarted(turnId: "t3", source: .user)))
        #expect(!thread.quietTurn)
        thread.apply(event(12, .messageAssistant(text: "back")))
        #expect(thread.items.contains { if case .assistant(_, "back", _) = $0 { true } else { false } })
    }

    @Test func aQuietRunLeavesThePreviewAsItWas() async throws {
        let agents = #"[{"id":"a","name":"Forge","runtime":"claude","cwd":"/x","last_message":null}]"#
        let fake = FakeTransport(handlers: daemonHandlers(lastSeq: 42, extra: ["agents.list": { _ in agents }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 43, text: "answer")))
        try await eventually { model.agents.first?.lastMessage?.text == "answer" }

        // The run's prompt, a quiet end, and a text the agent wrote anyway: none of them is the preview.
        let lines = [
            #"{"seq":44,"agent_id":"a","ts":44,"kind":"turn.started","payload":{"turn_id":"t","source":"schedule"}}"#,
            #"{"seq":45,"agent_id":"a","ts":45,"kind":"message.user","payload":{"text":"check the mail","source":"schedule","schedule":{"id":"s","name":"","fired_at":45}}}"#,
            #"{"seq":46,"agent_id":"a","ts":46,"kind":"turn.quiet","payload":{"turn_id":"t"}}"#,
            JSONRPC.messageEvent(seq: 47, text: "Nothing new"),
            #"{"seq":48,"agent_id":"a","ts":48,"kind":"turn.completed","payload":{"turn_id":"t","status":"ok"}}"#,
        ]
        for line in lines {
            await fake.push(JSONRPC.notification(line))
        }
        try await eventually { model.thread(for: "a").lastSeq == 48 }
        #expect(model.thread(for: "a").quietTurn)
        #expect(model.agents.first?.lastMessage?.text == "answer")
        await model.disconnect()
    }
}
