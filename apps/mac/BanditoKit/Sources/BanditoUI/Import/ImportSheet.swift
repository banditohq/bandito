import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// "Import from Claude Code": the agents, skills and commands of Claude Code and Codex on this Mac, with check boxes, a
/// preview of each, the names that are taken, and a report of what was made. Nothing on the Mac is changed.
struct ImportSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var plan = ImportPlan(items: [])
    @State private var skips: [ImportSkip] = []
    @State private var loading = true
    @State private var runtime: RuntimeKind = .claude
    @State private var previews: Set<String> = []
    @State private var runner = ImportRunner()

    private var server: ServerModel? { app.currentServer }
    private var agentsOK: Bool { server?.supports("agent_own_folder") ?? false }
    private var commandsOK: Bool { server?.supports("commands") ?? false }

    /// The runtimes an agent can be made on here; Claude when the server has not said.
    private var runtimes: [RuntimeKind] {
        let ready = BotLogic.availableRuntimes(server?.runtimes ?? [])
        return ready.isEmpty ? [.claude] : ready
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            if server == nil {
                Text(L10n.AgentSheet.noServer)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if runner.running || runner.finished {
                report
            } else {
                list
            }
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            footer
        }
        .frame(width: 720, height: 600)
        .background(Color.Bandito.surface2)
        .task { await load() }
        .onDisappear { runner.cancel() }
    }

    // MARK: header and footer

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.ClaudeImport.title)
                    .font(BanditoFont.display(size: 18.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Text(L10n.ClaudeImport.subtitle)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !runner.running && !runner.finished {
                Button(L10n.ClaudeImport.addFolder, action: addFolder)
                    .banditoButton(.quiet())
                    .fixedSize()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !runner.running && !runner.finished && plan.rows.contains(where: { $0.item.kind == .agent }) && agentsOK {
                Text(L10n.ClaudeImport.runtime)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                BanditoSelect(
                    selection: $runtime,
                    sections: [SelectSection(options: runtimes.map { SelectOption(value: $0, title: $0.title) })],
                    label: L10n.ClaudeImport.runtime, placeholder: "", style: .compact)
            }
            Spacer(minLength: 8)
            if runner.finished {
                Button(L10n.ClaudeImport.done) { dismiss() }
                    .banditoButton(.signal())
                    .fixedSize()
            } else {
                if runner.running {
                    Button(L10n.ClaudeImport.stop) { runner.cancel() }
                        .banditoButton(.quiet())
                        .fixedSize()
                } else {
                    Button(L10n.Common.cancel) { dismiss() }
                        .banditoButton(.quiet())
                        .fixedSize()
                }
                Button(runner.running ? L10n.ClaudeImport.running(done: String(runner.done), total: String(plan.count)) : L10n.ClaudeImport.start(count: plan.count)) {
                    start()
                }
                .banditoButton(.signal())
                .disabled(runner.running || !plan.canImport || server == nil)
                .fixedSize()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: the list

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if loading {
                    Text(L10n.ClaudeImport.scanning)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                } else if plan.rows.isEmpty {
                    Text(L10n.ClaudeImport.empty)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach([ImportKind.agent, .skill, .command], id: \.self) { kind in
                    group(kind)
                }
                if !skips.isEmpty { notTaken }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func group(_ kind: ImportKind) -> some View {
        let rows = plan.rows.filter { $0.item.kind == kind }
        if !rows.isEmpty {
            let enabled = kind == .agent ? agentsOK : commandsOK
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("\(Self.title(kind)) · \(rows.count)")
                    Spacer(minLength: 8)
                    if enabled {
                        let all = rows.filter { !$0.flagged }.allSatisfy(\.selected)
                        Button(all ? L10n.ClaudeImport.clearAll : L10n.ClaudeImport.selectAll) {
                            plan.setSelected(kind: kind, !all)
                        }
                        .banditoButton(.link)
                        .fixedSize()
                    }
                }
                if !enabled {
                    Text(kind == .agent ? L10n.ClaudeImport.needsAgentFolder : L10n.ClaudeImport.needsCommands)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(BanditoPalette.peach)
                }
                ForEach(rows) { row in
                    ImportRowView(
                        row: row, state: plan.state(of: row), enabled: enabled, runtime: runtime,
                        modelNote: modelNote(row.item), previewOpen: previews.contains(row.id),
                        onSelect: { plan.setSelected(row.id, $0) },
                        onResolution: { plan.setResolution(row.id, $0) },
                        onPreview: { if previews.contains(row.id) { previews.remove(row.id) } else { previews.insert(row.id) } })
                }
            }
        }
    }

    /// What was found and not taken, with the reason.
    private var notTaken: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(L10n.ClaudeImport.notTaken)
            ForEach(skips) { skip in
                Text(ImportText.reason(skip.reason, path: skip.path))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "The model is not offered" for an agent whose file names a model the runtime does not have.
    private func modelNote(_ item: ImportItem) -> String? {
        guard case .agent(let agent) = item.payload, let model = agent.model,
            ImportAgentParser.model(model, runtime: runtime, lists: server?.runtimeModels ?? [:]) == nil
        else { return nil }
        return L10n.ClaudeImport.Warning.model(model: model, runtime: runtime.title)
    }

    static func title(_ kind: ImportKind) -> String {
        switch kind {
        case .agent: L10n.ClaudeImport.Group.agents
        case .skill: L10n.ClaudeImport.Group.skills
        case .command: L10n.ClaudeImport.Group.commands
        }
    }

    // MARK: the report

    private var report: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                reportGroup(L10n.ClaudeImport.Report.created, lines: runner.lines.filter { $0.outcome == .created }, tint: Color.Bandito.ok, symbol: "checkmark.circle.fill")
                reportGroup(
                    L10n.ClaudeImport.Report.skipped,
                    lines: runner.lines.filter { if case .skipped = $0.outcome { true } else { false } },
                    tint: Color.Bandito.text3, symbol: "minus.circle")
                reportGroup(
                    L10n.ClaudeImport.Report.failed,
                    lines: runner.lines.filter { if case .failed = $0.outcome { true } else { false } },
                    tint: Color.Bandito.danger, symbol: "xmark.circle.fill")
                if runner.running {
                    Text(L10n.ClaudeImport.running(done: String(runner.done), total: String(plan.count)))
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func reportGroup(_ title: String, lines: [ImportLine], tint: Color, symbol: String) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("\(title) · \(lines.count)")
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(line.name)
                                    .font(BanditoFont.mono(size: 12.5, weight: 500))
                                    .foregroundStyle(Color.Bandito.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !line.id.hasPrefix("scan|") {
                                    Chip(text: ImportText.kind(line.kind))
                                }
                            }
                            if let why = ImportText.outcome(line) {
                                Text(why)
                                    .font(BanditoFont.text(size: 12, weight: 400))
                                    .foregroundStyle(line.outcome.isFailure ? Color.Bandito.danger : Color.Bandito.text3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: actions

    private func load() async {
        loading = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scan = await Task.detached(priority: .userInitiated) { ImportScanner.scan(home: home) }.value
        if let first = runtimes.first, !runtimes.contains(runtime) { runtime = first }
        skips = scan.skipped
        plan = ImportPlan(items: scan.items, existing: await existing())
        applySupport()
        loading = false
        _ = try? await server?.refreshRuntimes()
    }

    /// What the server has by these names. Without an agent to ask for its commands, only the agents are known, and a
    /// command or a skill that is there is found when the install is refused.
    private func existing() async -> ImportPlan.Existing {
        guard let server else { return ImportPlan.Existing() }
        var commands: [AgentCommand] = []
        if commandsOK, let any = server.agents.first {
            commands = (try? await server.commands(agentID: any.id)) ?? []
        }
        return ImportExisting.make(agents: server.agents, commands: commands)
    }

    /// A kind the server cannot take is not selected.
    private func applySupport() {
        if !agentsOK { plan.setSelected(kind: .agent, false) }
        if !commandsOK {
            plan.setSelected(kind: .skill, false)
            plan.setSelected(kind: .command, false)
        }
    }

    private func addFolder() {
        guard let folder = FilePanels.folderURL(message: L10n.ClaudeImport.folderMessage) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task {
            let scan = await Task.detached(priority: .userInitiated) { ImportScanner.scan(home: home, project: folder) }.value
            plan.add(scan.items)
            let known = Set(skips.map(\.id))
            skips += scan.skipped.filter { !known.contains($0.id) }
            applySupport()
        }
    }

    private func start() {
        guard let server, !runner.running else { return }
        runner.start(plan: plan, scanSkips: skips, server: server, runtime: runtime)
    }
}

/// The words for what an import did.
enum ImportText {
    static func kind(_ kind: ImportKind) -> String {
        switch kind {
        case .agent: L10n.ClaudeImport.Kind.agent
        case .skill: L10n.ClaudeImport.Kind.skill
        case .command: L10n.ClaudeImport.Kind.command
        }
    }

    /// Why something found was not taken, naming its path.
    static func reason(_ reason: ImportSkipReason, path: String) -> String {
        switch reason {
        case .tooBig: L10n.ClaudeImport.Skip.tooBig(path: path)
        case .notText: L10n.ClaudeImport.Skip.notText(path: path)
        case .link: L10n.ClaudeImport.Skip.link(path: path)
        case .sensitiveFile: L10n.ClaudeImport.Skip.sensitive(path: path)
        case .hidden: L10n.ClaudeImport.Skip.hidden(path: path)
        case .truncated: L10n.ClaudeImport.Skip.truncated(path: path)
        case .tooManyFiles: L10n.ClaudeImport.Skip.tooManyFiles(path: path)
        case .tooLarge: L10n.ClaudeImport.Skip.tooLarge(path: path)
        case .badName: L10n.ClaudeImport.Skip.badName(path: path)
        case .noSkillFile: L10n.ClaudeImport.Skip.noSkillFile(path: path)
        case .unreadable: L10n.ClaudeImport.Skip.unreadable(path: path)
        case .empty: L10n.ClaudeImport.Skip.empty(path: path)
        }
    }

    /// The line under an item of the report: why it was left or why it failed; nil for one that was made.
    static func outcome(_ line: ImportLine) -> String? {
        switch line.outcome {
        case .created: nil
        case .failed(let message): message.text
        case .skipped(let why):
            switch why {
            case .byYou: L10n.ClaudeImport.Reason.byYou
            case .exists: L10n.ClaudeImport.Reason.exists
            case .cancelled: L10n.ClaudeImport.Reason.cancelled
            case .notRead(let skip): Self.reason(skip, path: line.name)
            }
        }
    }
}

extension ImportLine.Outcome {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// One found item: the check box and the name, where it came from, the way out of a taken name, warnings and a preview.
private struct ImportRowView: View {
    let row: ImportPlan.Row
    let state: ImportPlan.State
    let enabled: Bool
    let runtime: RuntimeKind
    let modelNote: String?
    let previewOpen: Bool
    var onSelect: (Bool) -> Void
    var onResolution: (ImportPlan.Resolution) -> Void
    var onPreview: () -> Void

    private enum Choice: Hashable { case rename, skip }

    var body: some View {
        let item = row.item
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                CheckBoxRow(isOn: Binding(get: { row.selected && enabled }, set: onSelect), label: item.name)
                    .disabled(!enabled)
                Chip(text: Self.origin(item.origin))
                Spacer(minLength: 8)
                Button(previewOpen ? L10n.ClaudeImport.hidePreview : L10n.ClaudeImport.preview, action: onPreview)
                    .banditoButton(.link)
                    .fixedSize()
            }
            if let summary = item.summary {
                Text(summary)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(2)
                    .padding(.leading, 25)
            }
            if row.selected && enabled {
                conflict
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, text in
                    Label {
                        Text(text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(BanditoPalette.peach)
                }
            }
            .padding(.leading, 25)
            if previewOpen { preview }
        }
        .padding(.vertical, 6)
    }

    /// The way out of a taken name: Rename (with the new name in a field) or Skip.
    @ViewBuilder
    private var conflict: some View {
        if row.resolution != .keep {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Chip(text: L10n.ClaudeImport.conflict, tone: .warning)
                    SegmentedPicker(
                        selection: Binding(
                            get: { row.resolution == .skip ? Choice.skip : .rename },
                            set: { choice in
                                switch choice {
                                case .skip: onResolution(.skip)
                                case .rename: onResolution(.rename(renamed))
                                }
                            }),
                        options: [(Choice.rename, L10n.ClaudeImport.rename), (Choice.skip, L10n.ClaudeImport.skip)]
                    )
                    .fixedSize()
                }
                if row.resolution != .skip {
                    TextField(L10n.ClaudeImport.newName, text: Binding(get: { renamed }, set: { onResolution(.rename($0)) }))
                        .banditoField(error: problem != nil)
                        .font(BanditoFont.mono(size: 12.5, weight: 400))
                    if let problem {
                        Text(problem)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.danger)
                    }
                }
            }
            .padding(.leading, 25)
        }
    }

    /// The name typed for a rename; what the plan suggested while the row is skipped.
    private var renamed: String {
        if case .rename(let name) = row.resolution { return name }
        return ImportPlan.freeName(row.item.name, kind: row.item.kind, taken: [])
    }

    private var problem: String? {
        switch state {
        case .invalid(_, let problem):
            switch problem {
            case .empty: L10n.ClaudeImport.Problem.empty
            case .tooLong: L10n.ClaudeImport.Problem.tooLong
            case .badCharacters:
                row.item.kind == .agent ? L10n.ClaudeImport.Problem.badAgentName : L10n.ClaudeImport.Problem.badName
            }
        case .conflict: L10n.ClaudeImport.Problem.taken
        default: nil
        }
    }

    private var warnings: [String] {
        var out: [String] = []
        for warning in row.item.warnings {
            switch warning {
            case .leftOutFiles(let count): out.append(L10n.ClaudeImport.Warning.leftOut(count: count))
            case .looksLikeSecret: out.append(L10n.ClaudeImport.Warning.secret)
            }
        }
        if let modelNote { out.append(modelNote) }
        return out
    }

    private var preview: some View {
        let item = row.item
        return VStack(alignment: .leading, spacing: 8) {
            Text(item.path)
                .font(BanditoFont.mono(size: 11, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .truncationMode(.middle)
            if !item.notSent.isEmpty {
                Text(L10n.ClaudeImport.notSentFiles(files: item.notSent.joined(separator: ", ")))
                    .font(BanditoFont.text(size: 11.5, weight: 500))
                    .foregroundStyle(BanditoPalette.peach)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.frontMatter.isEmpty {
                Text(item.frontMatter.joined(separator: "\n"))
                    .font(BanditoFont.mono(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.bodyPreview.isEmpty {
                Text(item.bodyPreview)
                    .font(BanditoFont.mono(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.Bandito.line, lineWidth: 1))
        .padding(.leading, 25)
    }

    static func origin(_ origin: ImportOrigin) -> String {
        switch origin {
        case .claudeUser: L10n.ClaudeImport.Origin.user
        case .claudeProject(let name): L10n.ClaudeImport.Origin.project(name: name)
        case .codexPrompts: L10n.ClaudeImport.Origin.codex
        case .projectInstructions(let name): L10n.ClaudeImport.Origin.agentsMd(name: name)
        }
    }
}
