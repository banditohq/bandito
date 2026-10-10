import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// One line of "Capabilities": a feature or a runtime, and whether the server has it.
struct SetupLine: Identifiable, Hashable {
    var id: String
    var title: String
    var state: SetupReady
    /// What to do about a line that is not ready, in a word or two. Nil when there is nothing to add.
    var hint: String?
}

/// The chip of one "Capabilities" line: its text, its color, and a tooltip when the user has to act.
struct SetupBadge: Equatable {
    var text: String
    var tone: ChipTone
    var help: String?

    /// A runtime (Claude Code, Codex, Grok) is judged by the daemon's runtime report: installed, then logged in.
    /// Without a report for it, the setup status is shown.
    static func make(for line: SetupLine, runtimes: [RuntimeStatus]) -> SetupBadge {
        if let kind = RuntimeKind(rawValue: line.id), let status = runtimes.first(where: { $0.kind == kind }) {
            return runtime(status)
        }
        return SetupBadge(
            text: ServerFeaturesCard.label(line.state),
            tone: line.state == .ready ? .ok : .neutral,
            help: line.state == .ready ? nil : line.hint)
    }

    static func runtime(_ status: RuntimeStatus) -> SetupBadge {
        guard status.installed else {
            return SetupBadge(text: L10n.Server.Features.notInstalled, tone: .danger, help: nil)
        }
        switch status.loggedIn {
        case false?:
            let help = loginCommand(status.kind).map { L10n.Server.Features.loginHelp(command: $0) }
            return SetupBadge(text: L10n.Connect.needsLogin, tone: .warning, help: help)
        case true?:
            return SetupBadge(text: L10n.Setup.ready, tone: .ok, help: nil)
        case nil:
            return SetupBadge(text: L10n.Server.Features.installed, tone: .neutral, help: nil)
        }
    }

    /// The command that signs the runtime in on the server. Nil for kinds without a login.
    static func loginCommand(_ kind: RuntimeKind) -> String? {
        switch kind {
        case .claude: "claude login"
        case .codex: "codex login"
        case .grok: "grok login"
        case .api: nil
        }
    }
}

/// The calls the setup model makes to a server. `ServerModel` is the real one; tests pass a fake.
@MainActor
protocol SetupServer: AnyObject {
    func setupStatus() async throws -> SetupStatus
    func setupInstall(components: [String]) async throws -> String
    func setupJob(_ id: String, from offset: UInt64) async throws -> SetupJob
}

extension ServerModel: SetupServer {}

/// Setup state of the server: what is missing, and the install job the app runs for it (`setup.*`).
@MainActor
@Observable
final class SetupModel {
    private(set) var status: SetupStatus?
    private(set) var job: SetupJob?
    /// The job's log so far. The daemon sends only what is new since `offset`.
    private(set) var log = ""
    private(set) var error: UserFacingMessage?
    /// Whether this model is sending install requests right now. Only `install` sets it, so a job that was lost
    /// can never keep the buttons disabled.
    private(set) var installing = false
    /// How long to wait between two reads of the job. Tests make it short.
    @ObservationIgnored var pollInterval: Duration = .seconds(1)

    /// The state of each feature and runtime, in the order of the design.
    var lines: [SetupLine] {
        guard let f = status?.features else { return [] }
        return [
            SetupLine(
                id: "screen", title: L10n.Setup.Feature.screen, state: f.screen,
                hint: f.screen == .unsupported ? L10n.Setup.screenLinuxOnly : nil),
            SetupLine(id: "browser", title: L10n.Setup.Feature.browser, state: f.browser, hint: nil),
            SetupLine(id: "containers", title: L10n.Setup.Feature.containers, state: f.containers, hint: nil),
            SetupLine(id: "claude", title: L10n.Runtime.claude, state: f.agents.claude, hint: nil),
            SetupLine(id: "codex", title: L10n.Runtime.codex, state: f.agents.codex, hint: nil),
            SetupLine(id: "grok", title: L10n.Runtime.grok, state: f.agents.grok, hint: nil),
        ]
    }

    /// Components that are missing and that Bandito can install here.
    var missingInstallable: [String] {
        (status?.components ?? []).filter { !$0.installed && $0.installable }.map(\.id)
    }

    var isRunning: Bool { installing }

    /// The command to type in a terminal when the install needs an administrator password.
    var passwordCommand: String? {
        guard job?.state == .needsPassword else { return nil }
        return job?.command
    }

    func load(_ server: SetupServer) async {
        // A job still marked running while no install is sent is left over: it is dropped, not shown as running.
        if !installing, job?.state == .running {
            job = nil
        }
        do {
            status = try await server.setupStatus()
            error = nil
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    /// Starts an install and follows its log until the job ends. A read that fails is repeated once; if it fails
    /// again, the job is dropped (so nothing looks as if it still runs) and the error is shown.
    func install(_ components: [String], server: SetupServer) async {
        guard !components.isEmpty, !installing else { return }
        installing = true
        defer { installing = false }
        log = ""
        job = nil
        error = nil
        do {
            let id = try await server.setupInstall(components: components)
            var offset: UInt64 = 0
            while true {
                let snapshot = try await readJob(id, from: offset, server: server)
                job = snapshot
                log += snapshot.log
                offset = snapshot.offset
                if snapshot.state != .running { break }
                try await Task.sleep(for: pollInterval)
            }
            await load(server)
        } catch {
            job = nil
            self.error = UserFacingError.message(for: error)
        }
    }

    /// Reads the job from `offset`. A failed read is repeated once after a short wait, before the error is thrown.
    private func readJob(_ id: String, from offset: UInt64, server: SetupServer) async throws -> SetupJob {
        do {
            return try await server.setupJob(id, from: offset)
        } catch {
            try await Task.sleep(for: pollInterval)
            return try await server.setupJob(id, from: offset)
        }
    }
}

/// "Capabilities" card of the overview: what the server can do, with the install button and its log.
struct ServerFeaturesCard: View {
    let server: ServerModel
    @Bindable var setup: SetupModel
    @Environment(Router.self) private var router
    /// The whole log is open, not only its last lines. It is part of the page flow, so the page scrolls it.
    @State private var showsFullLog = false

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
                    .banditoButton(.signal())
                    .disabled(setup.isRunning)
                }
            }
            ForEach(setup.lines) { line in
                HStack(spacing: 10) {
                    Text(line.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let hint = line.hint, line.state != .ready {
                        Text(hint)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    let badge = SetupBadge.make(for: line, runtimes: server.runtimes)
                    Chip(text: badge.text, tone: badge.tone)
                        .fixedSize()
                        .optionalHelp(badge.help)
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
                    .banditoButton(.quiet())
                }
            }
            if let failed = setup.job?.failedComponent {
                Text(L10n.Setup.failed(component: failed))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.danger)
            } else if let error = setup.error {
                UserFacingErrorView(message: error)
            }
        }
        .task { await setup.load(server) }
    }

    /// Lines shown before the person opens the whole log.
    static let logPreviewLines = 12

    /// The newest lines of the job's log, and a button for the rest. No scroll of its own: a nested scroll area would
    /// take the wheel from the overview page, which must scroll as one piece. Opened, every line sits in the page flow.
    private func logPanel(_ job: SetupJob) -> some View {
        let text = setup.log.isEmpty ? job.step : setup.log
        let count = Self.logLines(text).count
        return VStack(alignment: .leading, spacing: 8) {
            Text(showsFullLog ? text : Self.logTail(text, lines: Self.logPreviewLines))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.Bandito.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if count > Self.logPreviewLines {
                Button {
                    showsFullLog.toggle()
                } label: {
                    Text(showsFullLog ? L10n.Setup.collapseLog : L10n.Setup.showFullLog(count: count))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.quiet())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The lines of `text`. The newline that ends the text does not start a line of its own.
    static func logLines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The last `lines` lines of `text`, joined back with newlines.
    static func logTail(_ text: String, lines: Int) -> String {
        logLines(text).suffix(lines).joined(separator: "\n")
    }

    static func label(_ state: SetupReady) -> String {
        switch state {
        case .ready: L10n.Setup.ready
        case .missing: L10n.Setup.missing
        case .unsupported: L10n.Setup.unsupported
        }
    }
}
