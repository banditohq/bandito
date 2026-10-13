import Foundation
import Testing

@testable import BanditoKit

/// What the demo daemon answers for a chat: changes, a saved attachment, and the hook the iPhone's demo script uses.
@Suite struct DemoDaemonChatTests {
    @MainActor @Test func theDemoChangesAreTwelveFilesWithTheirDiffs() async throws {
        let (server, _) = DemoDaemon.server(id: UUID(), name: "Demo", setup: DemoDaemonSetup(agentIDs: ["a1"]))
        await server.connect()
        let diff = try await server.changesDiff(agentID: "a1")
        #expect(diff.files.count == 12)
        #expect(diff.additions == 240 && diff.deletions == 30)
        let file = try await server.changedFile(agentID: "a1", path: diff.files[0].path)
        let hunks = UnifiedDiff.parse(file.diff)
        #expect(hunks.count == 2)
        // The headers' counts match the lines: nothing is dropped by the parser.
        #expect(hunks.flatMap(\.lines).filter { $0.kind == .added }.count == 6)
        #expect(hunks.flatMap(\.lines).filter { $0.kind == .removed }.count == 2)
    }

    @MainActor @Test func anUploadedFileComesBackAsAnAttachment() async throws {
        let (server, _) = DemoDaemon.server(id: UUID(), name: "Demo", setup: DemoDaemonSetup(agentIDs: ["a1"]))
        await server.connect()
        let saved = try await server.uploadAttachment(Data(repeating: 1, count: 300), name: "shot.png", agentId: "a1")
        #expect(saved.name == "shot.png" && saved.size == 300 && saved.mime == "image/png")
        #expect(AttachmentRules.isImage(name: saved.name))
    }

    @MainActor @Test func theHookHearsAMessageAndAStop() async throws {
        let (server, transport) = DemoDaemon.server(id: UUID(), name: "Demo", setup: DemoDaemonSetup(agentIDs: ["a1"]))
        await server.connect()
        let heard = Heard()
        await transport.setClientHook { call in heard.add(call) }
        try await server.send("hello", to: "a1")
        try await server.interrupt("a1")
        // The hook runs inside the daemon's actor before the answer is read by the model.
        #expect(heard.calls.map(\.method) == ["agents.send", "agents.interrupt"])
        #expect(heard.calls.first?.text == "hello")
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [DemoClientCall] = []
    var calls: [DemoClientCall] { lock.withLock { list } }
    func add(_ call: DemoClientCall) { lock.withLock { list.append(call) } }
}
