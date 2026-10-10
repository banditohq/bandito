import Foundation
import Testing

@testable import BanditoKit

/// The calls the chat makes: reactions, replies and form answers, and what a daemon without the features is spared.
@MainActor
@Suite struct ChatRPCTests {
    func info(features: [String]) -> String {
        let list = features.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"version":"0.0.0","hostname":"t","os":"macos","arch":"arm64","started_at":1,"last_seq":0,"features":[\#(list)]}"#
    }

    func connected(
        features: [String], extra: [String: FakeTransport.Handler] = [:], errors: [String: FakeTransport.Failure] = [:]
    ) async -> (ServerModel, FakeTransport) {
        var handlers = daemonHandlers(extra: extra)
        handlers["daemon.info"] = { [info = info(features: features)] _ in info }
        let fake = FakeTransport(handlers: handlers, errors: errors)
        let (model, _) = makeModel([fake])
        await model.connect()
        return (model, fake)
    }

    func params(_ text: String) throws -> [String: Any] {
        let request = try #require(JSONRPC.parse(text))
        return try #require(JSONSerialization.jsonObject(with: Data(request.paramsJSON.utf8)) as? [String: Any])
    }

    @Test func aReplyNamesTheMessageItAnswers() async throws {
        let (model, fake) = await connected(features: ["attachments"], extra: ["agents.send": { _ in "{}" }])
        try await model.send("yes", to: "a", replyTo: 7)
        let sent = JSONRPC.requests(of: "agents.send", in: await fake.sentTexts())
        let p = try params(try #require(sent.first))
        #expect(p["reply_to"] as? Int == 7)
        #expect(p["text"] as? String == "yes")
        await model.disconnect()
    }

    @Test func aDaemonWithoutAttachmentsGetsNoReplyTo() async throws {
        let (model, fake) = await connected(features: [], extra: ["agents.send": { _ in "{}" }])
        try await model.send("yes", to: "a", replyTo: 7)
        let sent = JSONRPC.requests(of: "agents.send", in: await fake.sentTexts())
        let p = try params(try #require(sent.first))
        #expect(p["reply_to"] == nil)
        await model.disconnect()
    }

    @Test func sendingAnUndeliveredMessageAgainKeepsItsReplyOnceOnly() async throws {
        let (model, fake) = await connected(features: ["attachments"], extra: ["agents.send": { _ in "{}" }])
        let lines = [
            #"{"seq":3,"agent_id":"a","ts":1,"kind":"message.user","payload":{"text":"yes","source":"user","reply_to":2,"queued":true}}"#,
            #"{"seq":4,"agent_id":"a","ts":2,"kind":"message.dropped","payload":{"seq":3,"reason":"restart"}}"#,
        ]
        for line in lines { model.apply(try RPCClient.decoder.decode(Event.self, from: Data(line.utf8))) }
        #expect(model.thread(for: "a").undeliveredSeqs == [3])

        try await model.resendUndelivered(3, of: "a")
        // The line is gone at once, and a second click sends nothing.
        #expect(model.thread(for: "a").undeliveredSeqs.isEmpty)
        try await model.resendUndelivered(3, of: "a")
        let sent = JSONRPC.requests(of: "agents.send", in: await fake.sentTexts())
        #expect(sent.count == 1)
        let p = try params(try #require(sent.first))
        #expect(p["text"] as? String == "yes")
        #expect(p["reply_to"] as? Int == 2)
        await model.disconnect()
    }

    @Test func aPlainMessageHasNoReplyTo() async throws {
        let (model, fake) = await connected(features: ["attachments"], extra: ["agents.send": { _ in "{}" }])
        try await model.send("hi", to: "a")
        let sent = JSONRPC.requests(of: "agents.send", in: await fake.sentTexts())
        #expect(try params(try #require(sent.first))["reply_to"] == nil)
        await model.disconnect()
    }

    @Test func reactingSendsTheEmojiAndTakingItOffSendsNull() async throws {
        let (model, fake) = await connected(features: ["reactions"], extra: ["messages.react": { _ in "{}" }])
        try await model.react("👍", toMessage: 5, of: "a")
        try await model.react(nil, toMessage: 5, of: "a")
        let sent = JSONRPC.requests(of: "messages.react", in: await fake.sentTexts())
        #expect(sent.count == 2)
        let on = try params(sent[0])
        #expect(on["emoji"] as? String == "👍" && on["seq"] as? Int == 5 && on["agent_id"] as? String == "a")
        let off = try params(sent[1])
        #expect(off["emoji"] is NSNull)
        await model.disconnect()
    }

    @Test func aDaemonWithoutTheFeatureIsNotCalled() async throws {
        let (model, fake) = await connected(
            features: [], extra: ["messages.react": { _ in "{}" }, "forms.answer": { _ in "{}" }])
        await #expect(throws: RPCError.self) { try await model.react("👍", toMessage: 1, of: "a") }
        await #expect(throws: RPCError.self) { try await model.answerForm("f", in: "a", action: .reject) }
        let sent = await fake.sentTexts()
        #expect(JSONRPC.requests(of: "messages.react", in: sent).isEmpty)
        #expect(JSONRPC.requests(of: "forms.answer", in: sent).isEmpty)
        #expect(FailureKind.classify(RPCError(code: -32602, message: "unsupported: forms is not available on this server")) == .reason("unsupported"))
        await model.disconnect()
    }

    @Test func answeringAFormSendsTheValuesUnderTheirOwnIds() async throws {
        let (model, fake) = await connected(features: ["forms"], extra: ["forms.answer": { _ in "{}" }])
        try await model.answerForm("f1", in: "a", action: .submit, values: ["subjectLine": .string("Hi")])
        let sent = JSONRPC.requests(of: "forms.answer", in: await fake.sentTexts())
        let p = try params(try #require(sent.first))
        #expect(p["form_id"] as? String == "f1")
        #expect(p["action"] as? String == "submit")
        #expect((p["values"] as? [String: Any])?["subjectLine"] as? String == "Hi")
        await model.disconnect()
    }

    @Test func aFormThatExpiredIsClosedInTheThreadAndTheErrorIsThrown() async throws {
        let spec = FormSpec(title: "T", fields: [FormField(id: "x", label: "X", type: .text)])
        let (model, _) = await connected(
            features: ["forms"],
            errors: ["forms.answer": { _ in #"{"code":-32602,"message":"expired"}"# }])
        // The form is in the thread, waiting.
        model.apply(Event(seq: 1, agentId: "a", ts: 1, body: .formRequested(formId: "f1", spec: spec)))
        #expect(model.thread(for: "a").pendingForms.count == 1)
        await #expect(throws: RPCError.self) {
            try await model.answerForm("f1", in: "a", action: .submit, values: [:])
        }
        #expect(model.thread(for: "a").pendingForms.isEmpty)
        await model.disconnect()
    }

    @Test func anAlreadyAnsweredFormStaysAsItIsUntilItsEventComes() async throws {
        let spec = FormSpec(title: "T", fields: [FormField(id: "x", label: "X", type: .text)])
        let (model, _) = await connected(
            features: ["forms"],
            errors: ["forms.answer": { _ in #"{"code":-32602,"message":"already_answered"}"# }])
        model.apply(Event(seq: 1, agentId: "a", ts: 1, body: .formRequested(formId: "f1", spec: spec)))
        do {
            try await model.answerForm("f1", in: "a", action: .reject)
            Issue.record("expected an error")
        } catch let error as RPCError {
            #expect(error.message == "already_answered")
        }
        #expect(model.thread(for: "a").pendingForms.count == 1)
        await model.disconnect()
    }

    @Test func historyAddsAFormThatIsStillOpenAndOlderThanThePage() async throws {
        let formJSON =
            #"[{"id":"old","agent_id":"a","status":"pending","spec":{"title":"Old one","kind":"question","fields":[{"id":"x","label":"X","type":"text"}]},"answer":null,"created_at":5,"answered_at":null}]"#
        let (model, fake) = await connected(
            features: ["forms"],
            extra: [
                "events.page": { _ in "[" + JSONRPC.messageEvent(seq: 50, text: "new") + "]" },
                "forms.list": { _ in formJSON },
            ])
        try await model.loadHistory("a")
        let t = model.thread(for: "a")
        #expect(t.pendingForms.map(\.formId) == ["old"])
        // It sits before the message, which is newer.
        #expect(t.items.map(\.id) == ["form-old", "s50"])
        let asked = try params(try #require(JSONRPC.requests(of: "forms.list", in: await fake.sentTexts()).first))
        #expect(asked["status"] as? String == "pending" && asked["agent_id"] as? String == "a")
        await model.disconnect()
    }

    @Test func historyAsksNoFormsOfADaemonWithoutThem() async throws {
        let (model, fake) = await connected(
            features: [], extra: ["events.page": { _ in "[]" }, "forms.list": { _ in "[]" }])
        try await model.loadHistory("a")
        #expect(JSONRPC.requests(of: "forms.list", in: await fake.sentTexts()).isEmpty)
        await model.disconnect()
    }

    @Test func reactionsOnAnOlderMessageSurviveAReload() async throws {
        let reaction = #"{"seq":60,"agent_id":"a","ts":60,"kind":"reaction","payload":{"seq":50,"emoji":"🔥","by":"user"}}"#
        let (model, _) = await connected(
            features: ["reactions"],
            extra: ["events.page": { _ in "[" + JSONRPC.messageEvent(seq: 50, text: "m") + "," + reaction + "]" }])
        try await model.loadHistory("a")
        #expect(model.thread(for: "a").chips(forMessage: 50).map(\.emoji) == ["🔥"])
        await model.disconnect()
    }
}
