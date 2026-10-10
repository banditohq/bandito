import Foundation
import Testing

@testable import BanditoKit

@Suite struct MentionsTests {
    private func decode(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    @Test func kindsUseTheWireNames() throws {
        let list = [
            Mention(kind: .integration, id: "i1", label: "Linear"),
            Mention(kind: .agent, id: "a2", label: "Scout"),
            Mention(kind: .file, id: "/w/src/main.rs", label: "main.rs"),
            Mention(kind: .browserTab, id: "T9", label: "Docs"),
        ]
        let data = try RPCClient.encoder.encode(list)
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(objects.map { $0["kind"] } == ["integration", "agent", "file", "browser_tab"])
        #expect(objects.allSatisfy { Set($0.keys) == ["kind", "id", "label"] })
        let back = try RPCClient.decoder.decode([Mention].self, from: data)
        #expect(back == list)
    }

    @Test func sendCarriesMentionsAndOmitsThemWhenThereAreNone() throws {
        let mention = Mention(kind: .browserTab, id: "T9", label: "Docs")
        let with = try RPCClient.encoder.encode(
            AgentSendRequest(agentId: "a1", text: "see @Docs", attachments: nil, mentions: [mention]))
        let object = try #require(try JSONSerialization.jsonObject(with: with) as? [String: Any])
        let sent = try #require(object["mentions"] as? [[String: String]])
        #expect(sent == [["kind": "browser_tab", "id": "T9", "label": "Docs"]])
        #expect(object["agent_id"] as? String == "a1")

        let without = try RPCClient.encoder.encode(AgentSendRequest(agentId: "a1", text: "hi", attachments: nil))
        let plain = try #require(try JSONSerialization.jsonObject(with: without) as? [String: Any])
        #expect(plain["mentions"] == nil)
    }

    @Test func messageUserCarriesItsMentions() throws {
        let e = try decode(
            #"{"seq":3,"agent_id":"a1","ts":1,"kind":"message.user","payload":{"text":"ask @Scout","source":"user","mentions":[{"kind":"agent","id":"a2","label":"Scout"},{"kind":"browser_tab","id":"T9","label":"Docs"}]}}"#
        )
        guard case .messageUser(let text, _, _, _, _, _, let mentions) = e.body else {
            Issue.record("wrong body \(e.body)")
            return
        }
        #expect(text == "ask @Scout")
        #expect(
            mentions == [
                Mention(kind: .agent, id: "a2", label: "Scout"), Mention(kind: .browserTab, id: "T9", label: "Docs"),
            ])
    }

    @Test func messageUserWithoutMentionsStillDecodes() throws {
        let e = try decode(#"{"seq":4,"agent_id":"a1","ts":1,"kind":"message.user","payload":{"text":"hi","source":"user"}}"#)
        guard case .messageUser(_, _, _, _, _, _, let mentions) = e.body else {
            Issue.record("wrong body \(e.body)")
            return
        }
        #expect(mentions.isEmpty)
    }

    @Test func aKindFromANewerDaemonStillLists() throws {
        let m = try RPCClient.decoder.decode(Mention.self, from: Data(#"{"kind":"spaceship","id":"x","label":"X"}"#.utf8))
        #expect(m.label == "X")
    }

    @Test func threadKeepsTheMentionsOfTheMessage() {
        var thread = AgentThread()
        let m = Mention(kind: .agent, id: "a2", label: "Scout")
        thread.apply(Event(seq: 1, agentId: "a1", ts: 5, body: .messageUser(text: "x @Scout", source: .user, fromAgent: nil, mentions: [m])))
        thread.apply(Event(seq: 2, agentId: "a1", ts: 6, body: .messageUser(text: "plain", source: .user, fromAgent: nil)))
        #expect(thread.mentions[1] == [m])
        #expect(thread.mentions[2] == nil)
    }

    @Test func anOlderPageBringsItsMentions() {
        var older = AgentThread()
        let m = Mention(kind: .file, id: "/w/a.txt", label: "a.txt")
        older.apply(Event(seq: 1, agentId: "a1", ts: 5, body: .messageUser(text: "@a.txt", source: .user, fromAgent: nil, mentions: [m])))
        var current = AgentThread()
        current.mergeMessageMeta(from: older)
        #expect(current.mentions[1] == [m])
    }

    @Test func mentionTokenIsAtAndTheLabel() {
        #expect(Mention(kind: .integration, id: "i", label: "Google Drive").token == "@Google Drive")
    }
}
