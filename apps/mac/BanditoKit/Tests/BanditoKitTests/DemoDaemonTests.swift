import Foundation
import Testing

@testable import BanditoKit

/// The demo daemon of the smoothness check answers the way the app reads a real daemon.
@Suite struct DemoDaemonTests {
    /// The catalogs are copies of the daemon's own files; a change there must be copied here too.
    @Test func theCatalogsAreTheDaemonsOwn() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["integrations_catalog", "skills_catalog", "agent_templates", "agent_bundles"] {
            let daemon = try Data(contentsOf: repo.appendingPathComponent("daemon/src/\(name).json"))
            let copy = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "DemoDaemon"))
            #expect(try Data(contentsOf: copy) == daemon, "apps/mac/BanditoKit/Sources/BanditoKit/Resources/DemoDaemon/\(name).json differs from daemon/src")
        }
    }

    @MainActor @Test func everyScreenGetsAnAnswerItCanRead() async throws {
        let (server, transport) = DemoDaemon.server(
            id: UUID(), name: "Demo", setup: DemoDaemonSetup(agentIDs: ["a1", "a2"]))
        await server.connect()
        #expect(server.state == .connected)
        #expect(server.supports("files") && server.supports("server_settings"))
        #expect(try await !server.integrationCatalog().isEmpty)
        #expect(try await !server.skillCatalog().isEmpty)
        #expect(try await !server.botTemplates().isEmpty)
        #expect(try await !server.agentBundles().isEmpty)
        #expect(try await !server.integrations().isEmpty)
        #expect(try await !server.usageLimits().isEmpty)
        let listing = try await server.list(DemoDaemonFiles.bigFolder)
        #expect(listing.entries.count == DemoDaemonFiles.bigFolderCount)
        #expect(try await server.list("~").path == DemoDaemonFiles.home)
        #expect(try await server.readText(DemoDaemonFiles.codeFile).content.count > 10_000)
        #expect(try await !server.projects().isEmpty)
        #expect(try await server.hostStats().cpus == 12)
        #expect(try await server.hostHistory(range: .hour).count == 360)
        #expect(try await !server.hostProcesses().owners.isEmpty)
        #expect(try await !server.hostPorts().ports.isEmpty)
        #expect(try await server.listWorkspaces().first?.agents == ["a1", "a2"])
        #expect(try await !server.devices().isEmpty)
        #expect(try await !server.backups().isEmpty)
        #expect(try await server.serverSettings().settings.maxRunningAgents == 4)
        #expect(try await !server.telegramStatus().configured)
        #expect(try await !server.daemonLog().lines.isEmpty)
        _ = try await server.setupStatus()
        try await server.refreshRuntimeModels()
        #expect(!server.runtimeModels.isEmpty)
        #expect(try await server.terminals().first?.id == DemoDaemonFiles.terminalID)
        // Terminal output pushed by the scenario reaches the attached stream.
        let stream = try await server.attach(DemoDaemonFiles.terminalID)
        await transport.emitTerminalOutput(lines: 3)
        var received = Data()
        for await chunk in stream.chunks {
            if case .output(let bytes) = chunk { received.append(bytes) }
            if String(decoding: received, as: UTF8.self).contains("[3/10000]") { break }
        }
        #expect(String(decoding: received, as: UTF8.self).contains("Linking"))
        await server.disconnect()
    }
}
