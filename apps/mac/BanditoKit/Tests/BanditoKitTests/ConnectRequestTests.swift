import Foundation
import Testing

@testable import BanditoKit

/// The agent's request to connect a service (`integration_requested` / `integration_request_ended`): how the events
/// decode, how a thread folds them, and the decline call.
@MainActor
@Suite struct ConnectRequestTests {
    func decode(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    func event(_ seq: Int64, _ body: EventBody) -> Event {
        Event(seq: seq, agentId: "a", ts: 1_000 + seq, body: body)
    }

    // MARK: decoding

    @Test func theRequestDecodes() throws {
        let e = try decode(
            #"{"seq":5,"agent_id":"a","ts":9,"kind":"integration_requested","payload":{"request_id":"r1","service":"github","reason":"to read your issues"}}"#
        )
        #expect(e.body == .integrationRequested(requestId: "r1", service: "github", reason: "to read your issues"))
        let bare = try decode(
            #"{"seq":6,"agent_id":"a","ts":9,"kind":"integration_requested","payload":{"request_id":"r2","service":"notion"}}"#
        )
        #expect(bare.body == .integrationRequested(requestId: "r2", service: "notion", reason: nil))
    }

    @Test func theEndDecodesAndAnUnknownStatusIsExpired() throws {
        let done = try decode(
            #"{"seq":7,"agent_id":"a","ts":9,"kind":"integration_request_ended","payload":{"request_id":"r1","status":"connected","integration":"github"}}"#
        )
        #expect(done.body == .integrationRequestEnded(requestId: "r1", status: .connected, integration: "github"))
        let declined = try decode(
            #"{"seq":8,"agent_id":"a","ts":9,"kind":"integration_request_ended","payload":{"request_id":"r1","status":"declined"}}"#
        )
        #expect(declined.body == .integrationRequestEnded(requestId: "r1", status: .declined, integration: nil))
        let odd = try decode(
            #"{"seq":9,"agent_id":"a","ts":9,"kind":"integration_request_ended","payload":{"request_id":"r1","status":"vanished"}}"#
        )
        #expect(odd.body == .integrationRequestEnded(requestId: "r1", status: .expired, integration: nil))
    }

    // MARK: the thread

    @Test func aRequestWaitsThenConnects() {
        var t = AgentThread()
        t.apply(event(1, .integrationRequested(requestId: "r1", service: "github", reason: "issues")))
        #expect(t.pendingConnects.map(\.requestId) == ["r1"])
        #expect(t.items.first?.id == "connect-r1")
        t.apply(event(2, .integrationRequestEnded(requestId: "r1", status: .connected, integration: "github")))
        #expect(t.pendingConnects.isEmpty)
        guard case .connect(let row)? = t.items.first else { Issue.record("expected a connect row"); return }
        #expect(row.outcome == .connected(integration: "github"))
        #expect(row.shownReason == "issues")
    }

    @Test func declinedAndExpiredCloseTheRow() {
        var t = AgentThread()
        t.apply(event(1, .integrationRequested(requestId: "r1", service: "github", reason: nil)))
        t.apply(event(2, .integrationRequested(requestId: "r2", service: "notion", reason: "  ")))
        #expect(t.pendingConnects.count == 2)
        t.apply(event(3, .integrationRequestEnded(requestId: "r1", status: .declined, integration: nil)))
        t.apply(event(4, .integrationRequestEnded(requestId: "r2", status: .expired, integration: nil)))
        #expect(t.pendingConnects.isEmpty)
        let outcomes: [ConnectOutcome] = t.items.compactMap {
            if case .connect(let row) = $0, let outcome = row.outcome { return outcome }
            return nil
        }
        #expect(outcomes == [.declined, .expired])
        // A reason of blanks is no reason.
        guard case .connect(let second) = t.items[1] else { Issue.record("expected a connect row"); return }
        #expect(second.shownReason == nil)
    }

    @Test func theEndMeetsTheRowWhenItsPageLoadsLater() {
        var newer = AgentThread()
        newer.apply(event(10, .integrationRequestEnded(requestId: "r1", status: .connected, integration: "github")))
        #expect(newer.items.isEmpty)
        var older = AgentThread()
        older.apply(event(5, .integrationRequested(requestId: "r1", service: "github", reason: nil)))
        #expect(older.pendingConnects.count == 1)
        older.mergeMessageMeta(from: newer)
        #expect(older.pendingConnects.isEmpty)
        guard case .connect(let row)? = older.items.first else { Issue.record("expected a connect row"); return }
        #expect(row.outcome == .connected(integration: "github"))
    }

    @Test func aRepeatedRequestEventAddsNoSecondCard() {
        var t = AgentThread()
        let body = EventBody.integrationRequested(requestId: "r1", service: "github", reason: nil)
        t.apply(event(1, body))
        t.apply(event(1, body))
        #expect(t.items.count == 1)
    }

    // MARK: declining

    func connected(features: [String], extra: [String: FakeTransport.Handler] = [:], errors: [String: FakeTransport.Failure] = [:])
        async -> (ServerModel, FakeTransport)
    {
        var handlers = daemonHandlers(extra: extra)
        let list = features.map { "\"\($0)\"" }.joined(separator: ",")
        let info =
            #"{"version":"0.0.0","hostname":"t","os":"macos","arch":"arm64","started_at":1,"last_seq":0,"features":[\#(list)]}"#
        handlers["daemon.info"] = { _ in info }
        let fake = FakeTransport(handlers: handlers, errors: errors)
        let (model, _) = makeModel([fake])
        await model.connect()
        return (model, fake)
    }

    @Test func decliningSendsTheRequestId() async throws {
        let (model, fake) = await connected(
            features: ["agent_connect"], extra: ["integrations.request_decline": { _ in "{}" }])
        try await model.declineConnect("r1")
        let sent = JSONRPC.requests(of: "integrations.request_decline", in: await fake.sentTexts())
        let text = try #require(sent.first)
        let request = try #require(JSONRPC.parse(text))
        let p = try #require(JSONSerialization.jsonObject(with: Data(request.paramsJSON.utf8)) as? [String: Any])
        #expect(p["request_id"] as? String == "r1")
        await model.disconnect()
    }

    func sentParams(_ method: String, _ fake: FakeTransport) async throws -> [String: Any] {
        let sent = JSONRPC.requests(of: method, in: await fake.sentTexts())
        let text = try #require(sent.first)
        let request = try #require(JSONRPC.parse(text))
        return try #require(JSONSerialization.jsonObject(with: Data(request.paramsJSON.utf8)) as? [String: Any])
    }

    @Test func everyConnectionACardStartsNamesTheRequestItAnswers() async throws {
        let integration = #"{"id":"i1","name":"fetch","kind":"stdio","enabled":true,"created_at":1}"#
        let (model, fake) = await connected(
            features: ["agent_connect"],
            extra: [
                "integrations.oauth_begin": { _ in #"{"authorize_url":"https://x.test/a","state":"s1"}"# },
                "integrations.device_begin": { _ in
                    #"{"flow_id":"f1","user_code":"AB-12","verification_uri":"https://x.test/d","expires_at":1,"interval":5}"#
                },
                "integrations.add": { _ in integration },
                "integrations.update": { _ in integration },
            ])
        let draft = NewIntegration(name: "linear", kind: .http, url: "https://mcp.linear.app/mcp")
        _ = try await model.oauthBegin(.draft(draft), connectRequestId: "r1")
        _ = try await model.deviceBegin(.existing(id: "i1"), connectRequestId: "r2")
        _ = try await model.addIntegration(
            NewIntegration(name: "fetch", kind: .stdio, command: "uvx", connectRequestId: "r3"))
        _ = try await model.updateIntegration("i1", patch: IntegrationPatch(enabled: true), connectRequestId: "r4")
        #expect(try await sentParams("integrations.oauth_begin", fake)["connect_request_id"] as? String == "r1")
        #expect(try await sentParams("integrations.device_begin", fake)["connect_request_id"] as? String == "r2")
        #expect(try await sentParams("integrations.add", fake)["connect_request_id"] as? String == "r3")
        let update = try await sentParams("integrations.update", fake)
        #expect(update["connect_request_id"] as? String == "r4" && update["id"] as? String == "i1")
        await model.disconnect()
    }

    @Test func aConnectionNobodyAskedForSendsNoRequestId() async throws {
        let (model, fake) = await connected(
            features: [],
            extra: ["integrations.oauth_begin": { _ in #"{"authorize_url":"https://x.test/a","state":"s1"}"# }])
        _ = try await model.oauthBegin(.existing(id: "i1"))
        #expect(try await sentParams("integrations.oauth_begin", fake)["connect_request_id"] == nil)
        await model.disconnect()
    }

    @Test func aRequestThatIsOverAlreadyIsNotAnError() async throws {
        let (model, _) = await connected(
            features: ["agent_connect"],
            errors: ["integrations.request_decline": { _ in #"{"code":-32602,"message":"already_answered"}"# }])
        try await model.declineConnect("r1")
        await model.disconnect()
    }

    @Test func aDaemonWithoutTheFeatureIsNotAsked() async throws {
        let (model, fake) = await connected(features: [])
        await #expect(throws: RPCError.self) { try await model.declineConnect("r1") }
        #expect(JSONRPC.requests(of: "integrations.request_decline", in: await fake.sentTexts()).isEmpty)
        await model.disconnect()
    }
}
