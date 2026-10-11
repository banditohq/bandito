import Foundation
import Testing

@testable import BanditoKit

/// The events of an agent that creates agents and of the buttons an agent shows (docs/ARCHITECTURE.md#agents-creating-agents
/// and #quick-replies): how they read from the wire, and what a thread makes of them.
@Suite struct AgentCreateAndQuickRepliesTests {
    private func decode(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    private var seq: Int64 = 0
    private mutating func ev(_ body: EventBody) -> Event {
        seq += 1
        return Event(seq: seq, agentId: "a", ts: 1_000 + seq, body: body)
    }

    private static let buttons = [
        QuickReplyButton(label: "Done", reply: "The mailbox is connected"),
        QuickReplyButton(label: "Later", reply: "Not now"),
    ]

    // MARK: wire

    @Test func quickRepliesReadFromTheWire() throws {
        let e = try decode(
            #"{"seq":5,"agent_id":"a","ts":9,"kind":"agent.quick_replies","payload":{"buttons":[{"label":"Done","reply":"Connected"},{"label":"Later","reply":"Not now"}],"link":{"label":"Open Gmail","url":"https://mail.google.com"},"progress":{"done":2,"total":6}}}"#
        )
        #expect(
            e.body
                == .agentQuickReplies(
                    buttons: [QuickReplyButton(label: "Done", reply: "Connected"), QuickReplyButton(label: "Later", reply: "Not now")],
                    link: QuickReplyLink(label: "Open Gmail", url: "https://mail.google.com"),
                    progress: QuickReplyProgress(done: 2, total: 6)))
        let bare = try decode(
            #"{"seq":6,"agent_id":"a","ts":9,"kind":"agent.quick_replies","payload":{"buttons":[{"label":"Yes","reply":"yes"}]}}"#)
        #expect(bare.body == .agentQuickReplies(buttons: [QuickReplyButton(label: "Yes", reply: "yes")], link: nil, progress: nil))
    }

    @Test func aSetThatDoesNotReadIsUnknownAndNeverBreaksAPage() throws {
        let e = try decode(#"{"seq":5,"agent_id":"a","ts":9,"kind":"agent.quick_replies","payload":{"buttons":"nope"}}"#)
        #expect(e.body == .unknown(kind: "agent.quick_replies"))
        let spawned = try decode(#"{"seq":5,"agent_id":"a","ts":9,"kind":"agent.spawned","payload":{"name":3}}"#)
        #expect(spawned.body == .unknown(kind: "agent.spawned"))
    }

    @Test func theCreationEventsReadFromTheWire() throws {
        let made = try decode(
            #"{"seq":7,"agent_id":"a","ts":9,"kind":"agent.spawned","payload":{"agent_id":"b2","name":"Mailer","role":"mail watcher","runtime":"claude","model":"sonnet","approved_by":"user"}}"#
        )
        #expect(
            made.body
                == .agentSpawned(
                    agentId: "b2", name: "Mailer", role: "mail watcher", runtime: "claude", model: "sonnet", approvedBy: .user))
        let by = try decode(
            #"{"seq":1,"agent_id":"b2","ts":9,"kind":"agent.created_by","payload":{"by_agent_id":"a","by_name":"Forge","approved_by":"policy"}}"#
        )
        #expect(by.body == .agentCreatedBy(byAgentId: "a", byName: "Forge", approvedBy: .policy))
    }

    @Test func anApprovalCarriesItsInputOnlyWhenTheDaemonSentOne() throws {
        let e = try decode(
            #"{"seq":6,"agent_id":"a1","ts":1,"kind":"approval.requested","payload":{"approval_id":"ap1","call_id":"c1","tool":"agent.create","title":"Create agent «Mailer»","reason":"agent: create","input":{"name":"Mailer","approval_mode":"risky","integrations_all":false}}}"#
        )
        guard case .approvalRequested(_, _, let tool, _, _, _, _, let input) = e.body else {
            Issue.record("wrong body \(e.body)")
            return
        }
        #expect(tool == "agent.create")
        #expect(input?["name"]?.string == "Mailer")
        let old = try decode(
            #"{"seq":6,"agent_id":"a1","ts":1,"kind":"approval.requested","payload":{"approval_id":"ap1","call_id":"c1","tool":"Bash","title":"ls","reason":"r"}}"#
        )
        guard case .approvalRequested(_, _, _, _, _, _, _, let none) = old.body else {
            Issue.record("wrong body")
            return
        }
        #expect(none == nil)
    }

    // MARK: the summary of an agent to create

    private func summaryJSON(snake: Bool) throws -> JSONValue {
        let payload =
            #"{"name":"Mailer","role":"mail watcher","runtime":"claude","model":"sonnet","effort":null,"approval_mode":"always","capabilities":["browser","team"],"integrations":["gmail"],"integrations_all":false,"schedules":[{"title":"Mail","prompt":"Check the mail","human_en":"every 5 minutes","human_ru":"каждые 5 минут"}],"folder":{"mode":"new","path":"/agents/mailer"},"instructions":"Watch the mail.","creator":"Forge"}"#
        // Through the app's decoder the object keys become camelCase; a stored payload keeps snake_case.
        if snake { return try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) }
        return try RPCClient.decoder.decode(JSONValue.self, from: Data(payload.utf8))
    }

    @Test(arguments: [true, false]) func theSummaryReadsInBothSpellings(snake: Bool) throws {
        let s = try #require(AgentCreateSummary(input: try summaryJSON(snake: snake)))
        #expect(s.name == "Mailer" && s.role == "mail watcher" && s.creator == "Forge")
        #expect(s.runtime == "claude" && s.model == "sonnet" && s.effort == nil)
        #expect(s.approvalMode == .always)
        #expect(s.capabilities == ["browser", "team"])
        #expect(s.services == ["gmail"] && !s.servicesAll)
        #expect(s.runs.count == 1)
        #expect(s.runs[0].timing(languageCode: "ru") == "каждые 5 минут")
        #expect(s.runs[0].timing(languageCode: "de") == "every 5 minutes")
        #expect(s.runs[0].shownName == "Mail")
        #expect(s.folderIsNew && s.folderPath == "/agents/mailer")
        #expect(s.instructions == "Watch the mail.")
    }

    @Test func aSummaryNeedsAName() {
        #expect(AgentCreateSummary(input: nil) == nil)
        #expect(AgentCreateSummary(input: .null) == nil)
        #expect(AgentCreateSummary(input: .object([:])) == nil)
        #expect(AgentCreateSummary(input: .object(["name": .string("")])) == nil)
        let bare = AgentCreateSummary(input: .object(["name": .string("X")]))
        #expect(bare?.capabilities == [] && bare?.runs.isEmpty == true)
        // A mode the app does not know reads as the safe one.
        #expect(bare?.approvalMode == .always)
    }

    // MARK: a thread

    @Test mutating func theNewestSetOfButtonsIsTheOneShown() {
        var t = AgentThread()
        t.apply(ev(.turnStarted(turnId: "t", source: .user)))
        t.apply(ev(.messageAssistant(text: "Connect the mailbox, then press the button.")))
        t.apply(
            ev(
                .agentQuickReplies(
                    buttons: Self.buttons, link: QuickReplyLink(label: "Open", url: "https://example.com"),
                    progress: QuickReplyProgress(done: 1, total: 3))))
        #expect(t.quickReplies?.buttons == Self.buttons)
        #expect(t.quickReplies?.progress == QuickReplyProgress(done: 1, total: 3))
        #expect(t.quickReplies?.link?.label == "Open")
        let first = t.quickReplies?.id
        // A newer set replaces it, link and progress included.
        t.apply(ev(.agentQuickReplies(buttons: [QuickReplyButton(label: "1", reply: "one")], link: nil, progress: nil)))
        #expect(t.quickReplies?.buttons == [QuickReplyButton(label: "1", reply: "one")])
        #expect(t.quickReplies?.link == nil && t.quickReplies?.progress == nil)
        #expect(t.quickReplies?.id != first)
    }

    @Test mutating func theButtonsStayWhileTheAgentGoesOnWriting() {
        var t = AgentThread()
        t.apply(ev(.turnStarted(turnId: "t", source: .user)))
        t.apply(ev(.agentQuickReplies(buttons: Self.buttons, link: nil, progress: nil)))
        t.apply(ev(.messageDelta(text: "Press")))
        t.apply(ev(.messageAssistant(text: "Press one of the buttons.")))
        t.apply(ev(.toolCall(callId: "c", tool: "x", title: "x", input: .null)))
        t.apply(ev(.agentStatus(status: .idle, detail: nil)))
        t.apply(ev(.turnCompleted(turnId: "t", status: .ok, usage: nil, costUsd: nil)))
        #expect(t.quickReplies?.buttons == Self.buttons)
        // They are state, not a row: the thread's items do not hold them.
        #expect(!t.items.contains { if case .note = $0 { return true } else { return false } })
    }

    @Test mutating func theButtonsGoWhenThePersonWritesAMessage() {
        var t = AgentThread()
        t.apply(ev(.agentQuickReplies(buttons: Self.buttons, link: nil, progress: nil)))
        t.apply(ev(.messageUser(text: "Connected", source: .user, fromAgent: nil)))
        #expect(t.quickReplies == nil)
    }

    @Test mutating func theButtonsGoWhenANewTurnBegins() {
        var t = AgentThread()
        t.apply(ev(.agentQuickReplies(buttons: Self.buttons, link: nil, progress: nil)))
        // A message of a teammate or a schedule is not the person writing, but it starts a turn.
        t.apply(ev(.messageUser(text: "run", source: .schedule, fromAgent: nil)))
        #expect(t.quickReplies != nil)
        t.apply(ev(.turnStarted(turnId: "t2", source: .schedule)))
        #expect(t.quickReplies == nil)
    }

    @Test mutating func aFormReplyIsThePersonWriting() {
        var t = AgentThread()
        t.apply(ev(.agentQuickReplies(buttons: Self.buttons, link: nil, progress: nil)))
        t.apply(ev(.formAnswered(formId: "f", action: .reply, values: nil, comment: nil, message: "my own words")))
        #expect(t.quickReplies == nil)
    }

    @Test mutating func buttonsThatCannotBePressedShowNothing() {
        var t = AgentThread()
        t.apply(ev(.agentQuickReplies(buttons: Self.buttons, link: nil, progress: nil)))
        t.apply(ev(.agentQuickReplies(buttons: [], link: nil, progress: nil)))
        #expect(t.quickReplies == nil)
        t.apply(ev(.agentQuickReplies(buttons: [QuickReplyButton(label: "", reply: "x"), QuickReplyButton(label: "x", reply: "")], link: nil, progress: nil)))
        #expect(t.quickReplies == nil)
        // A progress that is not a count is dropped, the buttons stay.
        t.apply(ev(.agentQuickReplies(buttons: Self.buttons, link: nil, progress: QuickReplyProgress(done: 9, total: 3))))
        #expect(t.quickReplies?.buttons == Self.buttons && t.quickReplies?.progress == nil)
    }

    @Test mutating func aReplayedSetDoesNotComeBack() {
        var t = AgentThread()
        let set = ev(.agentQuickReplies(buttons: Self.buttons, link: nil, progress: nil))
        t.apply(set)
        t.apply(ev(.messageUser(text: "Connected", source: .user, fromAgent: nil)))
        t.apply(set)  // the same event again (a re-subscribe): older than the last applied, ignored
        #expect(t.quickReplies == nil)
    }

    @Test mutating func theCreationEventsAreQuietLinesInTheirFeeds() {
        var creator = AgentThread()
        creator.apply(ev(.agentSpawned(agentId: "b", name: "Mailer", role: nil, runtime: "claude", model: nil, approvedBy: .user)))
        creator.apply(ev(.agentSpawned(agentId: "c", name: "Quiet", role: nil, runtime: "claude", model: nil, approvedBy: .policy)))
        #expect(creator.items.count == 2)
        guard case .note(_, let a, .crew, _) = creator.items[0], case .note(_, let b, .crew, _) = creator.items[1] else {
            Issue.record("expected two notes")
            return
        }
        #expect(a.contains("Mailer") && b.contains("Quiet"))
        #expect(a != b, "a creation that nobody was asked about says so")
        var created = AgentThread()
        created.apply(ev(.agentCreatedBy(byAgentId: "a", byName: "Forge", approvedBy: .user)))
        guard case .note(_, let text, .crew, _) = created.items[0] else {
            Issue.record("expected a note")
            return
        }
        #expect(text.contains("Forge"))
    }

    @Test mutating func aCreationApprovalKeepsItsSummaryUntilItIsAnswered() {
        var t = AgentThread()
        let input = JSONValue.object(["name": .string("Mailer")])
        t.apply(
            ev(
                .approvalRequested(
                    approvalId: "p1", callId: "c1", tool: "agent.create", title: "Create agent «Mailer»", command: "Mailer",
                    diff: nil, reason: "agent: create", input: input)))
        guard case .approval(let row) = t.items[0] else {
            Issue.record("expected an approval")
            return
        }
        #expect(row.tool == "agent.create" && row.input == input && row.state == .pending)
        t.apply(ev(.approvalResolved(approvalId: "p1", decision: .allow, by: .user, remember: false)))
        guard case .approval(let done) = t.items[0] else { return }
        #expect(done.input == input)
        #expect(done.state == .approved(by: .user, remember: false))
    }
}
