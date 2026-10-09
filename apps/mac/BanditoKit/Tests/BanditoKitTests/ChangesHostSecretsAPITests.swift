import Foundation
import Testing

@testable import BanditoKit

@MainActor
@Suite struct ChangesHostSecretsAPITests {
    nonisolated static let checkpoint =
        #"{"id":"c1","sha":"abc","label":"start","kind":"before","turn_id":"t1","created_at":1}"#

    nonisolated static let diff = #"{"from":"c1","to":null,"files":[{"path":"a.txt","status":"modified","additions":1,"deletions":1}]}"#

    nonisolated static let hostStats =
        #"{"os":"macos","kernel":"25","arch":"arm64","hostname":"mini","cpus":8,"cpu_percent":5.0,"load":[0.1,0.2,0.3],"mem_total":10,"mem_used":5,"swap_total":0,"swap_used":0,"disks":[],"net_rx_bps":0,"net_tx_bps":0,"uptime_s":60}"#

    nonisolated static let secret = #"{"name":"OPENAI_API_KEY","tail":"wxyz","agents":["*"],"updated_at":7}"#

    nonisolated static func changesHandlers(_ extra: [String: FakeTransport.Handler] = [:]) -> [String: FakeTransport.Handler] {
        var handlers: [String: FakeTransport.Handler] = [
            "changes.checkpoints": { _ in "[\(checkpoint)]" },
            "changes.diff": { _ in diff },
            "changes.file": { _ in #"{"diff":"@@ -1 +1 @@","truncated":true}"# },
            "changes.restore": { _ in #"{"restored":["a.txt"],"undo_checkpoint_id":"c9"}"# },
            "host.stats": { _ in hostStats },
            "host.history": { _ in
                #"{"points":[{"t":1,"cpu":1.5,"mem_used":2,"net_rx_bps":3,"net_tx_bps":4}]}"#
            },
            "host.processes": { _ in #"{"supported":true,"owners":[]}"# },
            "host.ports": { _ in #"{"supported":false,"ports":[]}"# },
            "host.kill": { _ in "{}" },
            "secrets.list": { _ in "[\(secret)]" },
            "secrets.set": { _ in secret },
            "secrets.delete": { _ in #"{"deleted":true}"# },
        ]
        handlers.merge(extra) { _, new in new }
        return handlers
    }

    func lastParams(_ method: String, _ fake: FakeTransport) async -> [String: Any] {
        paramsOf(JSONRPC.requests(of: method, in: await fake.sentTexts()).last ?? "{}")
    }

    // MARK: changes

    @Test func checkpointsSendAgentAndLimit() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.changesHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        let list = try await model.checkpoints(agentID: "a1", limit: 5)

        #expect(list.map(\.id) == ["c1"])
        let p = await lastParams("changes.checkpoints", fake)
        #expect(p["agent_id"] as? String == "a1")
        #expect(intValue(p["limit"]) == 5)
        await model.disconnect()
    }

    @Test func changesDiffSendsCheckpointIDsAndOmitsUnsetOnes() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.changesHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        let d = try await model.changesDiff(agentID: "a1", from: "c1")

        #expect(d.files.first?.path == "a.txt")
        let p = await lastParams("changes.diff", fake)
        #expect(p["agent_id"] as? String == "a1")
        #expect(p["from"] as? String == "c1")
        #expect(p["to"] == nil)
        await model.disconnect()
    }

    @Test func changedFileReturnsDiffAndTruncation() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.changesHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        let file = try await model.changedFile(agentID: "a1", path: "a.txt", to: "c2")

        #expect(file.diff == "@@ -1 +1 @@")
        #expect(file.truncated)
        let p = await lastParams("changes.file", fake)
        #expect(p["path"] as? String == "a.txt")
        #expect(p["to"] as? String == "c2")
        #expect(p["from"] == nil)
        await model.disconnect()
    }

    @Test func restoreSendsCheckpointAndPathsAndReturnsUndoID() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.changesHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        let result = try await model.restore(agentID: "a1", checkpointID: "c1", paths: ["a.txt"])

        #expect(result.restored == ["a.txt"])
        #expect(result.undo == "c9")
        let p = await lastParams("changes.restore", fake)
        #expect(p["checkpoint_id"] as? String == "c1")
        #expect(p["paths"] as? [String] == ["a.txt"])
        await model.disconnect()
    }

    // MARK: host

    @Test func hostCallsSendTheContractMethods() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.changesHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        #expect(try await model.hostStats().hostname == "mini")
        #expect(try await model.hostHistory(range: "1h").map(\.cpu) == [1.5])
        #expect(await lastParams("host.history", fake)["range"] as? String == "1h")
        #expect(try await model.hostProcesses().supported)
        #expect(try await model.hostPorts().ports.isEmpty)
        try await model.kill(pid: 42)
        #expect(intValue(await lastParams("host.kill", fake)["pid"]) == 42)
        await model.disconnect()
    }

    // MARK: secrets

    @Test func secretsCallsSendNamesAndAgentsAndNeverAskForValues() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.changesHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        let list = try await model.secrets()
        #expect(list.map(\.name) == ["OPENAI_API_KEY"])
        #expect(list.first?.tail == "wxyz")

        let saved = try await model.setSecret(name: "OPENAI_API_KEY", value: "sk-test-123456789", agents: ["*"])
        #expect(saved.agents == ["*"])
        let set = await lastParams("secrets.set", fake)
        #expect(set["name"] as? String == "OPENAI_API_KEY")
        #expect(set["value"] as? String == "sk-test-123456789")
        #expect(set["agents"] as? [String] == ["*"])

        #expect(try await model.deleteSecret(name: "OPENAI_API_KEY"))
        #expect(await lastParams("secrets.delete", fake)["name"] as? String == "OPENAI_API_KEY")
        await model.disconnect()
    }
}
