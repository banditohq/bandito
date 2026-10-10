import Foundation
import Testing

@testable import BanditoKit

/// The main agent of a server: the `lead` field of an agent, `agents.update {lead}`, and the feature `lead`.
@MainActor
@Suite struct LeadAgentWireTests {
    private nonisolated static func agentJSON(_ id: String, lead: Bool?) -> String {
        let field = lead.map { #","lead":\#($0)"# } ?? ""
        return #"{"id":"\#(id)","name":"\#(id)","runtime":"claude","cwd":"/x"\#(field)}"#
    }

    private func connected(features: [String], agents: [String]) async -> (ServerModel, FakeTransport) {
        let list = features.map { "\"\($0)\"" }.joined(separator: ",")
        var handlers = daemonHandlers(extra: [
            "agents.list": { _ in "[" + agents.joined(separator: ",") + "]" },
            "agents.update": { _ in LeadAgentWireTests.agentJSON("b", lead: true) },
        ])
        handlers["daemon.info"] = { _ in
            #"{"version":"0.0.0","hostname":"t","os":"macos","arch":"arm64","started_at":1,"last_seq":0,"features":[\#(list)]}"#
        }
        let fake = FakeTransport(handlers: handlers)
        let (model, _) = makeModel([fake])
        await model.connect()
        return (model, fake)
    }

    @Test func anAgentReadsLeadAndAnOldDaemonMeansNotMain() throws {
        let main = try RPCClient.decoder.decode(Agent.self, from: Data(Self.agentJSON("a", lead: true).utf8))
        #expect(main.lead)
        let plain = try RPCClient.decoder.decode(Agent.self, from: Data(Self.agentJSON("a", lead: false).utf8))
        #expect(!plain.lead)
        let old = try RPCClient.decoder.decode(Agent.self, from: Data(Self.agentJSON("a", lead: nil).utf8))
        #expect(!old.lead)
    }

    @Test func aPatchSendsLeadOnlyWhenSet() throws {
        func json(_ patch: AgentPatch) throws -> [String: Any] {
            let data = try RPCClient.encoder.encode(patch)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        #expect(try json(AgentPatch(lead: true))["lead"] as? Bool == true)
        #expect(try json(AgentPatch(lead: false))["lead"] as? Bool == false)
        #expect(try json(AgentPatch(role: "x"))["lead"] == nil)
    }

    @Test func theServerKnowsItsMainAgentFromTheData() async {
        let (model, _) = await connected(
            features: ["lead"], agents: [Self.agentJSON("a", lead: false), Self.agentJSON("b", lead: true)])
        #expect(model.leadAgentID == "b")
        await model.disconnect()
    }

    @Test func aDaemonWithoutTheFeatureHasNoMainAgent() async {
        let (model, _) = await connected(features: [], agents: [Self.agentJSON("a", lead: true)])
        #expect(model.leadAgentID == nil)
        await model.disconnect()
    }

    @Test func makingAnotherAgentMainSendsTheFlagAndClearsTheOldOneAtOnce() async throws {
        let (model, fake) = await connected(
            features: ["lead"], agents: [Self.agentJSON("a", lead: true), Self.agentJSON("b", lead: false)])
        #expect(model.leadAgentID == "a")
        try await model.setLead(agentID: "b", true)
        #expect(model.leadAgentID == "b")
        #expect(model.agents.filter(\.lead).map(\.id) == ["b"])
        let sent = JSONRPC.requests(of: "agents.update", in: await fake.sentTexts())
        let text = try #require(sent.first)
        let request = try #require(JSONRPC.parse(text))
        let p = try #require(JSONSerialization.jsonObject(with: Data(request.paramsJSON.utf8)) as? [String: Any])
        #expect(p["id"] as? String == "b")
        #expect(p["lead"] as? Bool == true)
        await model.disconnect()
    }
}
