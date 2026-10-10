import Foundation
import Testing

@testable import BanditoKit

/// Forms, reactions and replies as events: how they decode and how a thread folds them.
@Suite struct ChatEventsTests {
    func decode(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    // MARK: decoding

    @Test func formRequestedDecodesTheSpecBesideTheFormId() throws {
        let e = try decode(
            #"""
            {"seq":5,"agent_id":"a","ts":9,"kind":"form_requested","payload":{
              "form_id":"f1","title":"Letter","intro":"Check it","kind":"confirm","submit_label":"Send it","reject_label":"No",
              "fields":[
                {"id":"to","label":"To","type":"email","required":true,"placeholder":"name@example.com"},
                {"id":"body","label":"Text","type":"textarea","default":"Hi"},
                {"id":"color","label":"Color","type":"choice","options":["red","blue"],"help":"Pick"},
                {"id":"copy","label":"Copy me","type":"boolean","default":true}
              ]}}
            """#)
        guard case .formRequested(let id, let spec) = e.body else { Issue.record("wrong body \(e.body)"); return }
        #expect(id == "f1")
        #expect(spec.title == "Letter")
        #expect(spec.intro == "Check it")
        #expect(spec.kind == .confirm)
        #expect(spec.submitLabel == "Send it")
        #expect(spec.rejectLabel == "No")
        #expect(spec.fields.map(\.id) == ["to", "body", "color", "copy"])
        #expect(spec.fields[0].type == .email && spec.fields[0].isRequired)
        #expect(spec.fields[0].placeholder == "name@example.com")
        #expect(spec.fields[1].defaultValue == .string("Hi"))
        #expect(spec.fields[2].options == ["red", "blue"] && spec.fields[2].help == "Pick")
        #expect(spec.fields[3].defaultValue == .bool(true))
        #expect(!spec.fields[3].isRequired)
    }

    @Test func aFieldOfAKindThisAppDoesNotKnowIsPlainText() throws {
        let e = try decode(
            #"{"seq":5,"agent_id":"a","ts":9,"kind":"form_requested","payload":{"form_id":"f","title":"T","kind":"poll","fields":[{"id":"x","label":"X","type":"hologram"}]}}"#
        )
        guard case .formRequested(_, let spec) = e.body else { Issue.record("wrong body"); return }
        #expect(spec.kind == .question)
        #expect(spec.fields[0].type == .text)
    }

    @Test func formAnsweredDecodes() throws {
        let sub = try decode(
            #"{"seq":6,"agent_id":"a","ts":9,"kind":"form_answered","payload":{"form_id":"f1","action":"submit","values":{"name":"Ann","n":3}}}"#
        )
        #expect(
            sub.body
                == .formAnswered(
                    formId: "f1", action: .submit, values: ["name": .string("Ann"), "n": .number(3)], comment: nil))
        let rej = try decode(
            #"{"seq":7,"agent_id":"a","ts":9,"kind":"form_answered","payload":{"form_id":"f1","action":"reject","comment":"not now"}}"#
        )
        #expect(rej.body == .formAnswered(formId: "f1", action: .reject, values: nil, comment: "not now"))
        let gone = try decode(#"{"seq":8,"agent_id":"a","ts":9,"kind":"form_answered","payload":{"form_id":"f1","action":"expired"}}"#)
        #expect(gone.body == .formAnswered(formId: "f1", action: .expired, values: nil, comment: nil))
    }

    @Test func reactionDecodesWithAndWithoutAnEmoji() throws {
        let on = try decode(#"{"seq":9,"agent_id":"a","ts":1,"kind":"reaction","payload":{"seq":4,"emoji":"👍","by":"user"}}"#)
        #expect(on.body == .reaction(seq: 4, emoji: "👍", by: .user))
        let off = try decode(#"{"seq":10,"agent_id":"a","ts":1,"kind":"reaction","payload":{"seq":4,"by":"agent"}}"#)
        #expect(off.body == .reaction(seq: 4, emoji: nil, by: .agent))
        let nul = try decode(#"{"seq":11,"agent_id":"a","ts":1,"kind":"reaction","payload":{"seq":4,"emoji":null,"by":"user"}}"#)
        #expect(nul.body == .reaction(seq: 4, emoji: nil, by: .user))
    }

    @Test func aUserMessageCarriesItsReplyAndFiles() throws {
        let e = try decode(
            #"{"seq":12,"agent_id":"a","ts":1,"kind":"message.user","payload":{"text":"see","source":"user","reply_to":4,"attachments":[{"path":"/w/.bandito/attachments/2026-10-10/a.png","name":"a.png","size":12,"mime":"image/png"}]}}"#
        )
        #expect(
            e.body
                == .messageUser(
                    text: "see", source: .user, fromAgent: nil, replyTo: 4,
                    attachments: [
                        MessageAttachment(
                            path: "/w/.bandito/attachments/2026-10-10/a.png", name: "a.png", size: 12, mime: "image/png")
                    ]))
        // An old daemon sends neither.
        let plain = try decode(#"{"seq":13,"agent_id":"a","ts":1,"kind":"message.user","payload":{"text":"hi","source":"user"}}"#)
        #expect(plain.body == .messageUser(text: "hi", source: .user, fromAgent: nil))
    }

    // MARK: threads

    var seq: Int64 = 0

    mutating func ev(_ body: EventBody) -> Event {
        seq += 1
        return Event(seq: seq, agentId: "a", ts: 1_000 + seq, body: body)
    }

    static let spec = FormSpec(
        title: "Who?", kind: .question,
        fields: [
            FormField(id: "to_address", label: "To", type: .email, isRequired: true),
            FormField(id: "subjectLine", label: "Subject", type: .text),
        ])

    @Test mutating func aMessageKnowsItsSeqFromItsEvent() {
        var t = AgentThread()
        t.apply(ev(.messageUser(text: "q", source: .user, fromAgent: nil)))
        t.apply(ev(.messageAssistant(text: "a")))
        t.apply(ev(.messageUser(text: "from crew", source: .crew, fromAgent: "Scout")))
        let seqs = t.items.compactMap(\.messageSeq)
        // The crew message is no message of the person's: only the question and the answer.
        #expect(seqs == [1, 2])
        #expect(ThreadItem.messageID(seq: 2) == "s2")
        #expect(ThreadItem.assistant(id: "s7-s", text: "x", ts: 1).messageSeq == nil)
    }

    @Test mutating func reactionsAreKeptBySeqAndReplace() {
        var t = AgentThread()
        t.apply(ev(.messageAssistant(text: "a")))
        t.apply(ev(.reaction(seq: 1, emoji: "👍", by: .user)))
        #expect(t.chips(forMessage: 1) == [ReactionChip(emoji: "👍", byUser: true, byAgent: false)])
        // A new emoji replaces the old one of the same side.
        t.apply(ev(.reaction(seq: 1, emoji: "🔥", by: .user)))
        #expect(t.chips(forMessage: 1).map(\.emoji) == ["🔥"])
        t.apply(ev(.reaction(seq: 1, emoji: "👀", by: .agent)))
        #expect(t.chips(forMessage: 1).map(\.emoji) == ["🔥", "👀"])
        // The same emoji from both sides is one chip, lit for both.
        t.apply(ev(.reaction(seq: 1, emoji: "🔥", by: .agent)))
        #expect(t.chips(forMessage: 1) == [ReactionChip(emoji: "🔥", byUser: true, byAgent: true)])
        // Taking the person's off leaves the agent's.
        t.apply(ev(.reaction(seq: 1, emoji: nil, by: .user)))
        #expect(t.chips(forMessage: 1) == [ReactionChip(emoji: "🔥", byUser: false, byAgent: true)])
        #expect(t.reactions[1]?.mine == nil)
        #expect(t.chips(forMessage: 99).isEmpty)
    }

    @Test mutating func aReactionEventDoesNotCreateARow() {
        var t = AgentThread()
        t.apply(ev(.messageAssistant(text: "a")))
        t.apply(ev(.reaction(seq: 1, emoji: "👍", by: .user)))
        #expect(t.items.count == 1)
    }

    @Test mutating func aReplyAndItsFilesAreRemembered() {
        var t = AgentThread()
        t.apply(ev(.messageAssistant(text: "a")))
        let file = MessageAttachment(path: "/p/a.txt", name: "a.txt", size: 1, mime: "text/plain")
        t.apply(ev(.messageUser(text: "re", source: .user, fromAgent: nil, replyTo: 1, attachments: [file])))
        #expect(t.replies == [2: 1])
        #expect(t.attachments[2] == [file])
    }

    @Test mutating func mergingPagesKeepsTheNewerReactionOfEachSide() {
        // The newer page (seq 10, 11) holds the reaction events; the older page holds nothing about them.
        var newer = AgentThread()
        newer.apply(Event(seq: 10, agentId: "a", ts: 1, body: .reaction(seq: 3, emoji: "🔥", by: .user)))
        var older = AgentThread()
        older.apply(Event(seq: 4, agentId: "a", ts: 1, body: .reaction(seq: 3, emoji: "👍", by: .user)))
        older.apply(Event(seq: 5, agentId: "a", ts: 1, body: .reaction(seq: 3, emoji: "👀", by: .agent)))
        newer.mergeMessageMeta(from: older)
        #expect(newer.chips(forMessage: 3).map(\.emoji) == ["🔥", "👀"])
        // And the other way round: the older page does not win.
        older.mergeMessageMeta(from: newer)
        #expect(older.chips(forMessage: 3).map(\.emoji) == ["🔥", "👀"])
    }

    @Test mutating func aFormWaitsThenIsAnswered() {
        var t = AgentThread()
        t.apply(ev(.formRequested(formId: "f1", spec: Self.spec)))
        #expect(t.pendingForms.map(\.formId) == ["f1"])
        #expect(t.items.first?.id == "form-f1")
        let spelled = FormKeys.decodedSpelling(of: "to_address")
        t.apply(ev(.formAnswered(formId: "f1", action: .submit, values: [spelled: .string("a@b.c")], comment: nil)))
        #expect(t.pendingForms.isEmpty)
        guard case .form(let row)? = t.items.first else { Issue.record("expected a form row"); return }
        // The row has the field's own id, however the decoder spelled it.
        #expect(row.outcome == .submitted(values: ["to_address": .string("a@b.c")]))
    }

    @Test mutating func anAnswerFromTheWireKeepsTheFieldIds() throws {
        var t = AgentThread()
        t.apply(ev(.formRequested(formId: "f1", spec: Self.spec)))
        let answer = try decode(
            #"{"seq":99,"agent_id":"a","ts":9,"kind":"form_answered","payload":{"form_id":"f1","action":"submit","values":{"to_address":"a@b.c","subjectLine":"Hi"}}}"#
        )
        t.apply(answer)
        guard case .form(let row)? = t.items.first, case .submitted(let values)? = row.outcome else {
            Issue.record("expected an answered form")
            return
        }
        #expect(values == ["to_address": .string("a@b.c"), "subjectLine": .string("Hi")])
    }

    @Test mutating func aRejectedAndAnExpiredFormEnd() {
        var t = AgentThread()
        t.apply(ev(.formRequested(formId: "f1", spec: Self.spec)))
        t.apply(ev(.formRequested(formId: "f2", spec: Self.spec)))
        #expect(t.pendingForms.count == 2)
        t.apply(ev(.formAnswered(formId: "f1", action: .reject, values: nil, comment: "no")))
        t.apply(ev(.formAnswered(formId: "f2", action: .expired, values: nil, comment: nil)))
        #expect(t.pendingForms.isEmpty)
        let outcomes = t.items.compactMap { item -> FormOutcome? in
            if case .form(let row) = item { return row.outcome }
            return nil
        }
        #expect(outcomes == [.rejected(comment: "no"), .expired])
    }

    @Test mutating func theAnswerOfAFormWhoseRequestIsOnAnOlderPageStillCloses() {
        var newer = AgentThread()
        newer.apply(Event(seq: 20, agentId: "a", ts: 1, body: .formAnswered(formId: "f1", action: .reject, values: nil, comment: nil)))
        var older = AgentThread()
        older.apply(Event(seq: 5, agentId: "a", ts: 1, body: .formRequested(formId: "f1", spec: Self.spec)))
        #expect(older.pendingForms.count == 1)
        // The older page is put in front of the newer one: the answer meets its form.
        newer.items = older.items + newer.items
        newer.mergeMessageMeta(from: older)
        #expect(newer.pendingForms.isEmpty)
        #expect(newer.items.first == .form(FormRow(formId: "f1", spec: Self.spec, outcome: .rejected(comment: nil), ts: 1)))
    }

    @Test mutating func aFormTheDaemonHoldsOpenIsAddedByTime() {
        var t = AgentThread()
        t.apply(Event(seq: 1, agentId: "a", ts: 100, body: .messageAssistant(text: "old")))
        t.apply(Event(seq: 2, agentId: "a", ts: 300, body: .messageAssistant(text: "new")))
        t.addPending(form: FormRow(formId: "f", spec: Self.spec, ts: 200))
        #expect(t.items.map(\.id) == ["s1", "form-f", "s2"])
        // Twice is once.
        t.addPending(form: FormRow(formId: "f", spec: Self.spec, ts: 200))
        #expect(t.items.count == 3)
    }

    @Test mutating func aFormAnsweredMeanwhileIsNotAddedAsOpen() {
        var t = AgentThread()
        t.apply(Event(seq: 2, agentId: "a", ts: 300, body: .formAnswered(formId: "f", action: .expired, values: nil, comment: nil)))
        t.addPending(form: FormRow(formId: "f", spec: Self.spec, ts: 200))
        #expect(t.items.isEmpty)
    }

    @Test mutating func localCloseEndsAForm() {
        var t = AgentThread()
        t.apply(ev(.formRequested(formId: "f1", spec: Self.spec)))
        t.close(form: "f1", with: .expired)
        #expect(t.pendingForms.isEmpty)
    }

    @Test mutating func formsDoNotChangeThePreview() {
        var t = AgentThread()
        t.apply(ev(.messageAssistant(text: "hello")))
        t.apply(ev(.formRequested(formId: "f1", spec: Self.spec)))
        #expect(t.preview == "hello")
        #expect(t.lastMessageText == "hello")
    }
}
