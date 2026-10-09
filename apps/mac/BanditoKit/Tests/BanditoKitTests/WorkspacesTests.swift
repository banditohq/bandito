import Foundation
import Testing

@testable import BanditoKit

/// `workspaces.*` wire models. The JSON is the shape the daemon's own tests in daemon/src/rpc/workspaces.rs check.
@MainActor
@Suite struct WorkspacesTests {
    /// What `workspaces.create` answers for the container of the daemon test `create_list_update_delete`.
    nonisolated static let createdJSON = """
        {"id":"0190a1","name":"Scout box","kind":"container","image":null,"cpus":1.5,"memory_mb":1024,
         "network":"none","mounts":[],"created_at":1700000000000}
        """

    /// What `workspaces.list` answers: the shared row, a running container, and one Docker cannot answer for.
    nonisolated static let listJSON = """
        [
          {"id":"shared","name":"Shared","kind":"shared","image":null,"cpus":null,"memory_mb":null,
           "network":"internet","mounts":[],"created_at":0,"agents":["a1"],"status":null},
          {"id":"0190a1","name":"Scout box","kind":"container","image":null,"cpus":1.5,"memory_mb":1024,
           "network":"none","mounts":[{"host":"/Users/me/Projects/site","target":"/Users/me/Projects/site","read_only":true}],
           "created_at":1700000000000,"agents":["a2","a3"],
           "status":{"running":true,"container_id":"c0ffee","cpu":"0.10%","mem":"12MiB / 1GiB"}},
          {"id":"0190a2","name":"Box 2","kind":"container","image":null,"cpus":null,"memory_mb":null,
           "network":"internet","mounts":[],"created_at":1700000000001,"agents":[],
           "status":{"running":false,"error":"docker_unavailable"}}
        ]
        """

    nonisolated static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try RPCClient.decoder.decode(T.self, from: Data(text.utf8))
    }

    /// The request encoder of the RPC layer: snake_case keys.
    nonisolated static func encode(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(value)
        return object(String(decoding: data, as: UTF8.self))
    }

    // MARK: decoding

    @Test func createdWorkspaceDecodesItsSettings() throws {
        let w = try Self.decode(Workspace.self, Self.createdJSON)
        #expect(w.id == "0190a1")
        #expect(w.kind == .container)
        #expect(w.network == .offline, "wire value none")
        #expect(w.limits == WorkspaceLimits(cpus: 1.5, memoryMb: 1024))
        #expect(w.mounts.isEmpty)
        #expect(w.agents.isEmpty, "create answers the row alone")
        #expect(w.status == nil)
        #expect(w.image == nil)
    }

    @Test func listCarriesAgentsAndStatus() throws {
        let items = try Self.decode([Workspace].self, Self.listJSON)
        #expect(items.map(\.id) == ["shared", "0190a1", "0190a2"])

        let shared = items[0]
        #expect(shared.kind == .shared)
        #expect(shared.status == nil, "the shared workspace has no container status")
        #expect(shared.agents == ["a1"])
        #expect(shared.canDelete == false)

        let running = items[1]
        #expect(running.isRunning)
        #expect(running.status?.containerId == "c0ffee")
        #expect(running.status?.cpu == "0.10%")
        #expect(running.status?.mem == "12MiB / 1GiB")
        #expect(running.mounts == [WorkspaceMount(host: "/Users/me/Projects/site", target: "/Users/me/Projects/site", readOnly: true)])
        #expect(running.agents == ["a2", "a3"])

        let broken = items[2]
        #expect(broken.isRunning == false)
        #expect(broken.status?.running == false)
        #expect(broken.status?.error == "docker_unavailable")
        #expect(broken.limits == WorkspaceLimits(), "no limits: null on the wire")
    }

    @Test func mountWithoutReadOnlyIsWritable() throws {
        let m = try Self.decode(WorkspaceMount.self, #"{"host":"/a","target":"/a"}"#)
        #expect(m.readOnly == false)
    }

    @Test func unknownKindFallsBackToContainer() throws {
        let w = try Self.decode(Workspace.self, #"{"id":"x","name":"x","kind":"vm"}"#)
        #expect(w.kind == .container, "an unknown kind is never mistaken for the shared workspace")
        #expect(w.canDelete, "no agents, so the container can be deleted")
    }

    @Test func statusReadsAStartReply() throws {
        let s = try Self.decode(WorkspaceStatus.self, #"{"running":true,"container_id":"abc","cpu":null,"mem":null}"#)
        #expect(s.running)
        #expect(s.containerId == "abc")
        #expect(s.error == nil)
    }

    // MARK: rules

    @Test func deletingIsRefusedWhileAgentsRun() {
        let empty = Workspace(id: "a", name: "Box", kind: .container)
        #expect(empty.canDelete)

        var busy = empty
        busy.agents = ["scout"]
        #expect(busy.canDelete == false)

        let shared = Workspace(id: "shared", name: "Shared", kind: .shared)
        #expect(shared.canDelete == false, "the shared workspace is built in")
    }

    @Test func limitsRespectTheDaemonRanges() {
        #expect(WorkspaceLimits.defaults.isValid)
        #expect(WorkspaceLimits(cpus: 0.05).isValid == false)
        #expect(WorkspaceLimits(cpus: 64).isValid)
        #expect(WorkspaceLimits(memoryMb: 63).isValid == false)
        #expect(WorkspaceLimits(memoryMb: 262_144).isValid)
        #expect(WorkspaceLimits(cpus: nil, memoryMb: nil).isValid, "unset means no limit")
    }

    // MARK: requests

    @Test func newWorkspaceOmitsUnsetFields() throws {
        let body = try Self.encode(NewWorkspace(name: "Box", network: .offline, mounts: []))
        #expect(body["kind"] as? String == "container")
        #expect(body["network"] as? String == "none")
        #expect(body["mounts"] as? [Any] != nil)
        #expect(body["image"] == nil)
        #expect(body["cpus"] == nil)
        #expect(body["memory_mb"] == nil)
    }

    @Test func clearingALimitSendsNull() throws {
        let patch = WorkspacePatch(name: "Watch", cpus: .clear, memoryMb: .set(512))
        let body = try Self.encode(patch)
        #expect(body["name"] as? String == "Watch")
        #expect(body.keys.contains("cpus"))
        #expect(body["cpus"] is NSNull)
        #expect(intValue(body["memory_mb"]) == 512)
        #expect(body["image"] == nil, "an untouched field is not sent")
        #expect(body["mounts"] == nil)
    }

    @Test func settingMountsSendsTheWholeList() throws {
        let patch = WorkspacePatch(mounts: [])
        let body = try Self.encode(patch)
        #expect((body["mounts"] as? [Any])?.isEmpty == true, "an empty list still clears the folders")
    }

    @Test func agentRequestsCarryTheWorkspace() throws {
        let create = NewAgent(name: "Scout", runtime: .claude, cwd: "/w", workspaceId: "0190a1")
        #expect(try Self.encode(create)["workspace_id"] as? String == "0190a1")

        let plain = NewAgent(name: "Scout", runtime: .claude, cwd: "/w")
        #expect(try Self.encode(plain)["workspace_id"] == nil, "no key: the daemon uses the shared workspace")

        let move = try Self.encode(AgentPatch(workspaceId: "0190a1"))
        #expect(move["workspace_id"] as? String == "0190a1")
        #expect(move.count == 1, "a move sends only the workspace")
    }

    // MARK: errors

    @Test func workspaceErrorsNameTheirReason() {
        func failure(_ reason: String, code: Int = RPCError.workspaceError) -> WorkspaceFailure? {
            WorkspaceFailure(RPCError(code: code, message: "daemon text", data: .object(["reason": .string(reason)])))
        }
        #expect(failure("docker_unavailable") == .dockerUnavailable)
        #expect(failure("not_found") == .notFound)
        #expect(failure("builtin") == .builtin)
        #expect(failure("not_empty") == .notEmpty)
        #expect(failure("invalid") == .invalid(message: "daemon text"))
        #expect(failure("docker") == .docker(message: "daemon text"))
        #expect(failure("something_new") == .other(message: "daemon text"))
        #expect(failure("not_empty", code: RPCError.fileError) == nil, "other codes are not workspace failures")
        #expect(WorkspaceFailure(RPCError(code: RPCError.timedOut, message: "slow")) == nil)
    }

    // MARK: the server model

    @Test func listSendsOneRequestAndDecodes() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: ["workspaces.list": { _ in Self.listJSON }]))
        let (model, _) = makeModel([fake])
        await model.connect()
        let items = try await model.listWorkspaces()
        #expect(items.count == 3)
        #expect(JSONRPC.requests(of: "workspaces.list", in: await fake.sentTexts()).count == 1)
        await model.disconnect()
    }

    @Test func deleteOfANonEmptyWorkspaceFailsWithItsReason() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(),
            errors: [
                "workspaces.delete": { _ in
                    #"{"code":-32028,"message":"the workspace still has 2 agent(s); move them first","data":{"reason":"not_empty"}}"#
                }
            ])
        let (model, _) = makeModel([fake])
        await model.connect()
        do {
            try await model.deleteWorkspace("0190a1")
            Issue.record("expected a refusal")
        } catch {
            #expect(WorkspaceFailure(error) == .notEmpty)
        }
        await model.disconnect()
    }

    @Test func updateSendsIdAndClearsWithNull() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(extra: [
                "workspaces.update": { _ in Self.createdJSON }
            ]))
        let (model, _) = makeModel([fake])
        await model.connect()
        let updated = try await model.updateWorkspace("0190a1", patch: WorkspacePatch(cpus: .clear))
        #expect(updated.name == "Scout box")
        let params = paramsOf(JSONRPC.requests(of: "workspaces.update", in: await fake.sentTexts()).last ?? "{}")
        #expect(params["id"] as? String == "0190a1")
        #expect(params["cpus"] is NSNull)
        await model.disconnect()
    }
}
