import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// One line of "Capabilities": a feature or a runtime, and whether the server has it.
struct SetupLine: Identifiable, Hashable {
    var id: String
    var title: String
    var state: SetupReady
}

/// Setup state of the server: what is missing, and the install job the app runs for it (`setup.*`).
@MainActor
@Observable
final class SetupModel {
    private(set) var status: SetupStatus?
    private(set) var job: SetupJob?
    /// The job's log so far. The daemon sends only what is new since `offset`.
    private(set) var log = ""
    private(set) var error: String?

    /// The state of each feature and runtime, in the order of the design.
    var lines: [SetupLine] {
        guard let f = status?.features else { return [] }
        return [
            SetupLine(id: "screen", title: L10n.Setup.Feature.screen, state: f.screen),
            SetupLine(id: "browser", title: L10n.Setup.Feature.browser, state: f.browser),
            SetupLine(id: "containers", title: L10n.Setup.Feature.containers, state: f.containers),
            SetupLine(id: "claude", title: L10n.Runtime.claude, state: f.agents.claude),
            SetupLine(id: "codex", title: L10n.Runtime.codex, state: f.agents.codex),
            SetupLine(id: "grok", title: L10n.Runtime.grok, state: f.agents.grok),
        ]
    }

    /// Components that are missing and that Bandito can install here.
    var missingInstallable: [String] {
        (status?.components ?? []).filter { !$0.installed && $0.installable }.map(\.id)
    }

    var isRunning: Bool { job?.state == .running }

    /// The command to type in a terminal when the install needs an administrator password.
    var passwordCommand: String? {
        guard job?.state == .needsPassword else { return nil }
        return job?.command
    }

    func load(_ server: ServerModel) async {
        do {
            status = try await server.setupStatus()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Starts an install and follows its log about once a second until the job ends.
    func install(_ components: [String], server: ServerModel) async {
        guard !components.isEmpty, !isRunning else { return }
        log = ""
        job = nil
        error = nil
        do {
            let id = try await server.setupInstall(components: components)
            var offset: UInt64 = 0
            while true {
                let snapshot = try await server.setupJob(id, from: offset)
                job = snapshot
                log += snapshot.log
                offset = snapshot.offset
                if snapshot.state != .running { break }
                try await Task.sleep(for: .seconds(1))
            }
            await load(server)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// "Capabilities" card of the overview: what the server can do, with the install button and its log.
struct ServerFeaturesCard: View {
    let server: ServerModel
    @Bindable var setup: SetupModel
    @Environment(Router.self) private var router

    var body: some View {
        ServerCard {
            HStack(spacing: 10) {
                SectionLabel(L10n.Server.Features.title)
                Spacer(minLength: 8)
                if !setup.missingInstallable.isEmpty {
                    Button(L10n.Setup.install) {
                        let ids = setup.missingInstallable
                        Task { await setup.install(ids, server: server) }
                    }
                    .buttonStyle(SignalButtonStyle())
                    .disabled(setup.isRunning)
                }
            }
            ForEach(setup.lines) { line in
                HStack(spacing: 10) {
                    Text(line.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text)
                    Spacer(minLength: 8)
                    Chip(text: Self.label(line.state), tone: line.state == .ready ? .ok : .neutral)
                }
            }
            if let job = setup.job {
                logPanel(job)
            }
            if let command = setup.passwordCommand {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Setup.needsPassword)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Bandito.text2)
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button(L10n.Setup.openTerminal) {
                        router.requestTerminalCommand(command)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            if let failed = setup.job?.failedComponent {
                Text(L10n.Setup.failed(component: failed))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.danger)
            } else if let error = setup.error {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.danger)
            }
        }
        .task { await setup.load(server) }
    }

    private func logPanel(_ job: SetupJob) -> some View {
        ScrollView {
            Text(setup.log.isEmpty ? job.step : setup.log)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.Bandito.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: 140)
        .padding(10)
        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func label(_ state: SetupReady) -> String {
        switch state {
        case .ready: L10n.Setup.ready
        case .missing: L10n.Setup.missing
        case .unsupported: L10n.Setup.unsupported
        }
    }
}
