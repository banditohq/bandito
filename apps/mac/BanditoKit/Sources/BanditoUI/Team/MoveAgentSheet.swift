import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// "Перенести на…": the agent moves to another connected server (docs/ARCHITECTURE.md#agent-migration). The person
/// chooses the server and the project folder there, then sees the steps with a bar. "Готово" opens the agent there.
/// A failure says what happened; the source is left as it was, unless the text says otherwise.
struct MoveAgentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    let source: ServerModel
    let agent: Agent
    /// The servers the agent can move to (see `MigrationTargets.eligible`).
    let targets: [ServerModel]

    @State private var targetID: UUID?
    @State private var folderMode: NewAgentFolderMode = .newFolder
    /// The agents folder on the target, where a new project folder is made. Empty until it is known.
    @State private var root = ""
    @State private var existingFolder = ""
    @State private var rootPickerOpen = false
    @State private var existingPickerOpen = false
    @State private var folderError: UserFacingMessage?
    @State private var preparing = false
    /// The move in progress or finished; nil while the person chooses.
    @State private var migration: AgentMigration?
    /// The target and project folder of the move, so "Повторить" starts the same move again.
    @State private var runTarget: ServerModel?
    @State private var runFolder: String?

    init(source: ServerModel, agent: Agent, targets: [ServerModel], preselectedTargetID: UUID? = nil) {
        self.source = source
        self.agent = agent
        self.targets = targets
        _targetID = State(initialValue: preselectedTargetID)
    }

    private var target: ServerModel? { targets.first { $0.id == targetID } }

    /// A project folder is chosen: a new one in the agents folder (the server can make it), or an existing one.
    private var folderReady: Bool {
        guard let target else { return false }
        if folderMode == .newFolder, target.supports("files") { return !root.isEmpty }
        return !existingFolder.isEmpty
    }

    private var canStart: Bool { target != nil && folderReady && !preparing }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            content
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: 520)
        .task(id: targetID) { await resolveDefaults(target) }
    }

    // MARK: header and phases

    private var headerTitle: String {
        if case .done(let outcome) = migration?.step {
            return L10n.Migrate.Done.title(name: agent.name, server: outcome.targetName)
        }
        return L10n.Migrate.title(name: agent.name)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerTitle)
                .font(BanditoFont.display(size: 18.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if migration == nil {
                Text(L10n.Migrate.hint)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    @ViewBuilder private var content: some View {
        if let run = migration {
            switch run.step {
            case .done(let outcome): done(outcome)
            case .failed(let failure): failed(failure, run: run)
            default: running(run)
            }
        } else {
            chooser
        }
    }

    @ViewBuilder private var footer: some View {
        if let run = migration {
            switch run.step {
            case .done(let outcome):
                footerBar {
                    Button(L10n.Migrate.Done.button) { openTarget(outcome) }
                        .banditoButton(.signal())
                }
            case .failed:
                footerBar {
                    Button(L10n.Common.close) { router.sheet = nil }
                        .banditoButton(.quiet())
                    Button(L10n.Migrate.retry) { retry() }
                        .banditoButton(.signal())
                }
            default:
                footerBar {
                    if MoveAgentProgress.isStoppable(run.step) {
                        Button(L10n.Migrate.stop) { run.cancel() }
                            .banditoButton(.quiet())
                    }
                }
            }
        } else {
            footerBar {
                Button(L10n.Common.cancel) { router.sheet = nil }
                    .banditoButton(.quiet())
                Button(L10n.Migrate.start) { start() }
                    .banditoButton(.signal())
                    .disabled(!canStart)
            }
        }
    }

    /// The bottom row of the sheet: the buttons in `ActionRow`, pushed to the trailing edge.
    private func footerBar<Buttons: View>(@ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            ActionRow {
                buttons()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(Color.Bandito.bg.opacity(0.4))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
        }
    }

    // MARK: choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(L10n.Migrate.target)
                if targets.isEmpty {
                    Text(L10n.Migrate.noTargets)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                } else {
                    VStack(spacing: 6) {
                        ForEach(targets, id: \.id) { candidate in
                            serverRow(candidate)
                        }
                    }
                }
            }
            if let target {
                folderSection(target)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serverRow(_ candidate: ServerModel) -> some View {
        let selected = candidate.id == targetID
        return Button {
            targetID = candidate.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.Bandito.signal : Color.Bandito.text3)
                Text(candidate.config.name)
                    .font(BanditoFont.text(size: 13.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.Bandito.signal)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                selected ? Color.Bandito.text.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 10))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func folderSection(_ target: ServerModel) -> some View {
        let canMake = target.supports("files")
        return VStack(alignment: .leading, spacing: 9) {
            SectionLabel(L10n.Migrate.folder)
            if canMake {
                SegmentedPicker(
                    selection: $folderMode,
                    options: [
                        (NewAgentFolderMode.newFolder, L10n.AgentSheet.folderNew),
                        (NewAgentFolderMode.existing, L10n.AgentSheet.folderExisting),
                    ])
            }
            if canMake && folderMode == .newFolder {
                newFolderField(target)
            } else {
                existingFolderField(target)
            }
            if !folderReady {
                Text(L10n.Migrate.Folder.pick)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let folderError {
                UserFacingErrorView(message: folderError)
            }
        }
    }

    /// "New folder": the agents folder on the target, and the folder the agent gets (named after the agent).
    private func newFolderField(_ target: ServerModel) -> some View {
        let preview = root.isEmpty
            ? nil
            : NewAgentFolderRules.folderPath(root: root, name: NewAgentFolderRules.folderName(for: agent.name))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14))
                    .foregroundStyle(BanditoPalette.peach)
                Text(preview ?? L10n.AgentSheet.folderRootNone)
                    .font(BanditoFont.mono(size: 13, weight: 400))
                    .foregroundStyle(preview == nil ? Color.Bandito.text3 : Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(root.isEmpty ? L10n.AgentSheet.folderChoose : L10n.AgentSheet.folderChange) {
                    rootPickerOpen.toggle()
                }
                .banditoButton(.link)
                .popover(isPresented: $rootPickerOpen, arrowEdge: .top) {
                    // The agents folder is not a project: it stays out of "Recent" and is kept for this server.
                    FolderPicker(
                        server: target, selection: $root,
                        onChoose: {
                            rootPickerOpen = false
                            if !root.isEmpty {
                                AgentsRootStore.save(root, serverID: target.id.uuidString)
                            }
                        },
                        remembersChoice: false)
                }
            }
            .modifier(FieldBox())
            Text(L10n.AgentSheet.folderNewHint)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Existing": a folder that is already on the target, picked in its folder browser.
    private func existingFolderField(_ target: ServerModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                existingPickerOpen.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(BanditoPalette.peach)
                    Text(existingFolder.isEmpty ? L10n.AgentSheet.noFolder : existingFolder)
                        .font(BanditoFont.mono(size: 13, weight: 400))
                        .foregroundStyle(existingFolder.isEmpty ? Color.Bandito.text3 : Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(FieldBox())
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 12))
            .accessibilityLabel(L10n.AgentSheet.folderAccessibility)
            .popover(isPresented: $existingPickerOpen, arrowEdge: .top) {
                FolderPicker(server: target, selection: $existingFolder, onChoose: { existingPickerOpen = false })
            }
        }
    }

    /// The agents folder and the default folder kind for a newly picked target.
    private func resolveDefaults(_ target: ServerModel?) async {
        guard let target else { return }
        existingFolder = ""
        folderError = nil
        folderMode = target.supports("files") ? .newFolder : .existing
        let home = (try? await target.stat("~"))?.path
        let projects = target.agents.compactMap { NewAgentFolderRules.projectFolder(cwd: $0.cwd, homeDir: $0.homeDir) }
        let saved = AgentsRootStore.load(serverID: target.id.uuidString)
        root = NewAgentFolderRules.defaultRoot(saved: saved, projectFolders: projects, home: home) ?? ""
    }

    // MARK: starting

    private func start() {
        guard let target, canStart else { return }
        preparing = true
        folderError = nil
        Task {
            let folder: String?
            do {
                folder = try await projectFolder(on: target)
            } catch {
                preparing = false
                folderError = UserFacingError.message(for: error).wrapped {
                    L10n.AgentSheet.folderCreateFailed(message: $0)
                }
                return
            }
            preparing = false
            guard let folder else {
                folderError = UserFacingMessage(text: L10n.AgentSheet.folderNoFreeName)
                return
            }
            launch(on: target, folder: folder)
        }
    }

    private func retry() {
        guard let runTarget, let runFolder else { return }
        launch(on: runTarget, folder: runFolder)
    }

    private func launch(on target: ServerModel, folder: String) {
        runTarget = target
        runFolder = folder
        let sourceAgent = source.agents.first { $0.id == agent.id } ?? agent
        let run = AgentMigration(
            agentID: agent.id, source: source, target: target, targetFolder: folder,
            sourceAgentPaused: sourceAgent.paused)
        migration = run
        Task {
            await run.start()
            if case .done(let outcome) = run.step, let moved = outcome.agent {
                MovedAgentLink.save(
                    MovedAgentLink.Value(serverID: target.id, agentID: moved.id),
                    sourceServerID: source.id, agentID: agent.id)
            }
        }
    }

    /// The project folder the agent gets on the target: a new one named after the agent (made with `fs.*` when it
    /// does not exist yet; a free `<name> N` when the name is taken), or the existing folder the person picked.
    /// Nil when no free name turned up.
    private func projectFolder(on target: ServerModel) async throws -> String? {
        guard folderMode == .newFolder, target.supports("files") else { return existingFolder }
        do {
            _ = try await target.stat(root)
        } catch let failure as RPCError where failure.reason == "not_found" {
            _ = try await target.mkdir(root)
        }
        let base = NewAgentFolderRules.folderName(for: agent.name)
        for attempt in 1...NewAgentFolderRules.attemptLimit {
            let name = NewAgentFolderRules.candidate(base: base, attempt: attempt)
            let path = NewAgentFolderRules.folderPath(root: root, name: name)
            switch try await Self.folderSlot(path, on: target) {
            case .missing:
                _ = try await target.mkdir(path)
                return path
            case .empty:
                return path
            case .taken:
                continue
            }
        }
        return nil
    }

    /// What is at `path`: nothing, an empty folder, or something taken. Hidden entries count, as in the new agent sheet.
    private static func folderSlot(_ path: String, on target: ServerModel) async throws -> AgentFolderSlot {
        let entry: FsEntry
        do {
            entry = try await target.stat(path)
        } catch let failure as RPCError where failure.reason == "not_found" {
            return .missing
        }
        guard entry.kind == .dir else { return .taken }
        let listing = try await target.list(path, hidden: true)
        return listing.entries.isEmpty ? .empty : .taken
    }

    // MARK: running, done, failed

    private func running(_ run: AgentMigration) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(MoveAgentProgress.caption(run.step))
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
            MoveProgressBar(fraction: MoveAgentProgress.fraction(run.step))
            if let fraction = MoveAgentProgress.fraction(run.step) {
                Text(L10n.Migrate.progress(percent: "\(MoveAgentProgress.wholePercent(fraction))"))
                    .font(BanditoFont.mono(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<MoveAgentProgress.stepCount, id: \.self) { index in
                    stepRow(index: index, active: MoveAgentProgress.activeIndex(run.step))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepRow(index: Int, active: Int) -> some View {
        HStack(spacing: 9) {
            Group {
                if index < active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.Bandito.ok)
                } else if index == active {
                    Circle()
                        .fill(Color.Bandito.signal)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .stroke(Color.Bandito.text3, lineWidth: 1)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 16)
            Text(MoveAgentProgress.label(index))
                .font(BanditoFont.text(size: 12.5, weight: index == active ? 600 : 400))
                .foregroundStyle(index > active ? Color.Bandito.text3 : Color.Bandito.text)
        }
    }

    private func done(_ outcome: MigrationOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !outcome.missingServices.isEmpty {
                noteLine(L10n.Migrate.Note.missing(services: outcome.missingServices.joined(separator: ", ")))
            }
            if !outcome.downgraded.isEmpty {
                noteLine(L10n.Migrate.Note.downgraded)
            }
            if outcome.skippedCount > 0 {
                noteLine(L10n.Migrate.Note.skipped(count: outcome.skippedCount))
            }
            if !outcome.errors.isEmpty {
                let text = outcome.errors.map { "\($0.step): \($0.message)" }.joined(separator: "; ")
                noteLine(L10n.Migrate.Note.errors(message: text))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteLine(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 12.5, weight: 400))
            .foregroundStyle(Color.Bandito.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func failed(_ failure: MigrationFailure, run: AgentMigration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.failureText(failure, server: runTarget?.config.name ?? ""))
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            if run.sourceLeftPaused {
                Text(L10n.Migrate.Fail.stillPaused)
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(BanditoPalette.peach)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The sentence for a failed move. `server` is the target's name.
    static func failureText(_ failure: MigrationFailure, server: String) -> String {
        switch failure {
        case .busy:
            L10n.Migrate.Fail.busy
        case .cancelled:
            L10n.Migrate.Fail.cancelled
        case .changedSinceExport(_, let copyRemoved):
            copyRemoved
                ? L10n.Migrate.Fail.changed(server: server)
                : L10n.Migrate.Fail.changedCopyKept(server: server)
        case .refused(let phase, let reason, let message):
            // After the target's commit the copy exists: say so, rather than a bare refusal.
            phase == .finishing
                ? L10n.Migrate.Fail.copyKept(server: server)
                : L10n.Migrate.Fail.refused(message: message.isEmpty ? (reason ?? "—") : message)
        case .unsupported:
            L10n.Migrate.Fail.unsupported
        case .notConnected:
            L10n.Migrate.Fail.notConnected
        }
    }

    /// Opens the agent on the target: the server in front, its team, and the new agent when the move gave its id.
    private func openTarget(_ outcome: MigrationOutcome) {
        guard let target = runTarget else { return }
        app.selectedServerID = target.id
        if let moved = outcome.agent {
            router.selectAgent(moved.id, on: target)
        }
        router.select(mode: .team)
        router.sheet = nil
    }
}

/// The steps of a move as the sheet shows them, and the bar's share. Pure, so the mapping is tested in BanditoUITests.
enum MoveAgentProgress {
    /// Packing, transfer, unpacking and done: the steps the list shows.
    static let stepCount = 4

    /// The index of the step in progress; the done step (3) only once everything is finished. Pausing and packing
    /// both belong to the first step; marking the agent on this server belongs to unpacking.
    static func activeIndex(_ step: MigrationStep) -> Int {
        switch step {
        case .pausing, .packing, .failed: 0
        case .transferring: 1
        case .unpacking, .finishing: 2
        case .done: 3
        }
    }

    static func label(_ index: Int) -> String {
        switch index {
        case 0: L10n.Migrate.Step.pack
        case 1: L10n.Migrate.Step.transfer
        case 2: L10n.Migrate.Step.unpack
        default: L10n.Migrate.Step.done
        }
    }

    /// The line above the bar: the wait for the pause and the marking are named apart from the steps.
    static func caption(_ step: MigrationStep) -> String {
        switch step {
        case .pausing: L10n.Migrate.Step.pause
        case .finishing: L10n.Migrate.Step.finish
        default: label(activeIndex(step))
        }
    }

    /// The share of the archive that reached the target; nil while it is not known (the bar then shows no fill).
    static func fraction(_ step: MigrationStep) -> Double? {
        if case .transferring(let fraction) = step { return fraction }
        return nil
    }

    static func wholePercent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded(.down))
    }

    /// Only a move that has not reached the target's commit can be stopped.
    static func isStoppable(_ step: MigrationStep) -> Bool {
        switch step {
        case .pausing, .packing, .transferring: true
        default: false
        }
    }
}

/// The move's bar. Without a share it stays empty.
private struct MoveProgressBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Bandito.text.opacity(0.08))
                Capsule()
                    .fill(Color.Bandito.signal)
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, fraction ?? 0))))
            }
        }
        .frame(height: 6)
        .banditoAnimation(.easeOut(duration: BanditoMotion.base), value: fraction)
    }
}

/// Where a moved agent is, as this Mac saw it: the server and the agent's id there. Kept per source agent, so
/// "Открыть там" opens that very agent. Another Mac has no link and finds the agent by its name.
enum MovedAgentLink {
    struct Value: Equatable {
        var serverID: UUID
        var agentID: String
    }

    static func key(sourceServerID: UUID, agentID: String) -> String {
        "migrate.link.\(sourceServerID.uuidString).\(agentID)"
    }

    static func save(_ value: Value, sourceServerID: UUID, agentID: String, defaults: UserDefaults = .standard) {
        defaults.set("\(value.serverID.uuidString)|\(value.agentID)", forKey: key(sourceServerID: sourceServerID, agentID: agentID))
    }

    static func load(sourceServerID: UUID, agentID: String, defaults: UserDefaults = .standard) -> Value? {
        guard let text = defaults.string(forKey: key(sourceServerID: sourceServerID, agentID: agentID)),
            let bar = text.firstIndex(of: "|"),
            let serverID = UUID(uuidString: String(text[..<bar]))
        else { return nil }
        return Value(serverID: serverID, agentID: String(text[text.index(after: bar)...]))
    }
}
