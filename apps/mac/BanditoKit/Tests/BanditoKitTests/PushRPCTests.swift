import Foundation
import Testing

@testable import BanditoKit

/// The phone's side of `push.*` (docs/ARCHITECTURE.md#push) and the notice an event makes without a server.
@MainActor
@Suite struct PushRPCTests {
    func connected(features: [String], extra: [String: FakeTransport.Handler] = [:]) async -> (ServerModel, FakeTransport) {
        var handlers = daemonHandlers(extra: extra)
        let list = features.map { "\"\($0)\"" }.joined(separator: ",")
        handlers["daemon.info"] = { _ in
            #"{"version":"0.0.0","hostname":"t","os":"macos","arch":"arm64","started_at":1,"last_seq":0,"features":[\#(list)]}"#
        }
        let fake = FakeTransport(handlers: handlers, errors: [:])
        let (model, _) = makeModel([fake])
        await model.connect()
        return (model, fake)
    }

    func params(_ text: String) throws -> [String: Any] {
        let request = try #require(JSONRPC.parse(text))
        return try #require(JSONSerialization.jsonObject(with: Data(request.paramsJSON.utf8)) as? [String: Any])
    }

    @Test func pushIsSupportedOnlyWhenTheDaemonSaysSo() async {
        let (with, _) = await connected(features: ["push"])
        #expect(with.supportsPush)
        await with.disconnect()
        let (without, _) = await connected(features: ["schedules"])
        #expect(!without.supportsPush)
        await without.disconnect()
    }

    @Test func registeringSendsTheHandleTheKeyAndTheKinds() async throws {
        let (model, fake) = await connected(features: ["push"], extra: ["push.register": { _ in #"{"ok":true}"# }])
        let key = Data(repeating: 0xAB, count: 32)
        try await model.pushRegister(
            handle: "h1", key: key, serverRef: "S1", kinds: ["approval", "done"], lang: "ru-RU")
        let sent = JSONRPC.requests(of: "push.register", in: await fake.sentTexts())
        let p = try params(try #require(sent.first))
        #expect(p["handle"] as? String == "h1")
        #expect(p["key"] as? String == key.base64EncodedString())
        #expect(p["server_ref"] as? String == "S1")
        #expect(p["kinds"] as? [String] == ["approval", "done"])
        #expect(p["lang"] as? String == "ru-RU")
        await model.disconnect()
    }

    @Test func aMissingLanguageIsLeftOut() async throws {
        let (model, fake) = await connected(features: ["push"], extra: ["push.register": { _ in #"{"ok":true}"# }])
        try await model.pushRegister(handle: "h", key: Data(count: 32), serverRef: "S", kinds: ["error"], lang: nil)
        let sent = JSONRPC.requests(of: "push.register", in: await fake.sentTexts())
        #expect(try params(try #require(sent.first))["lang"] == nil)
        await model.disconnect()
    }

    @Test func unregisterAndStatus() async throws {
        let (model, fake) = await connected(
            features: ["push"],
            extra: ["push.unregister": { _ in #"{"ok":true}"# }, "push.status": { _ in #"{"registered":true}"# }])
        try await model.pushUnregister()
        #expect(try await model.pushIsRegistered())
        let texts = await fake.sentTexts()
        #expect(JSONRPC.requests(of: "push.unregister", in: texts).count == 1)
        #expect(JSONRPC.requests(of: "push.status", in: texts).count == 1)
        await model.disconnect()
    }

    @Test func aNoticeIsMadeFromAnEventAndANameAlone() throws {
        func event(_ line: String) throws -> Event { try RPCClient.decoder.decode(Event.self, from: Data(line.utf8)) }
        let approval = try event(
            #"{"seq":1,"agent_id":"a","ts":1,"kind":"approval.requested","payload":{"approval_id":"ap","call_id":"c","tool":"bash","title":"Run ls","command":"ls","reason":"rule: ask"}}"#)
        #expect(
            AgentNotice.notice(for: approval, agentName: "Forge", quietTurn: { false })
                == .approval(agentID: "a", agentName: "Forge", approvalID: "ap", title: "Run ls", command: "ls", reviewOnly: false))
        let done = try event(#"{"seq":2,"agent_id":"a","ts":1,"kind":"turn.completed","payload":{"turn_id":"t","status":"ok"}}"#)
        #expect(AgentNotice.notice(for: done, agentName: "Forge", quietTurn: { false }) == .finished(agentID: "a", agentName: "Forge"))
        // A quiet turn finishes with no notice; the check runs only for a finished turn.
        #expect(AgentNotice.notice(for: done, agentName: "Forge", quietTurn: { true }) == nil)
        #expect(AgentNotice.notice(for: approval, agentName: "Forge", quietTurn: { Issue.record("asked"); return true }) != nil)
    }
}
