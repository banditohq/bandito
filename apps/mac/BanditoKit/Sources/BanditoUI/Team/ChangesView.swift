import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// How the diff is laid out: one column, or old and new side by side.
enum ChangesViewMode: Hashable {
    case inline, sideBySide
}

/// "What changed": the files an agent changed since a restore point, their diffs, and what to do about
/// them (keep, roll back, ask the agent). A tab of the workbench (⌘⇧D). Design: docs/design/Changes.dc.html.
struct ChangesContent: View {
    var agentID: String
    /// Closes the view: the tab's close, or the sheet's. Called after "Keep" with nothing to change, after a rollback,
    /// and after the agent was asked.
    var onDone: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    @State private var checkpoints: [Checkpoint] = []
    @State private var loaded = false
    /// The restore point the diff is taken from.
    @State private var base: Checkpoint?
    @State private var diff: ChangesDiff?
    /// The base the current `diff` was taken from. A file is read only after the diff matches the base.
    @State private var diffBase: String?
    /// Paths whose "keep" box is ticked. Unticked files go back to the base on "Keep".
    @State private var keep: Set<String> = []
    @State private var selectedPath: String?
    @State private var file: FileState = .idle
    /// The line the user picked; `nil` means the first change.
    @State private var focus: ChangeLocation?
    @State private var viewMode: ChangesViewMode = .inline
    @State private var loadError: UserFacingMessage?
    @State private var busy = false
    @State private var confirmRollback = false
    /// Below this width the list goes on top of the diff, not beside it.
    static let sideBySideMinWidth: CGFloat = 700

    private var server: ServerModel? { app.currentServer }
    private var agent: Agent? { server?.agents.first { $0.id == agentID } }
    private var timeline: [Checkpoint] { RestorePoints.timeline(checkpoints) }
    private var files: [FileChange] { diff?.files ?? [] }
    private var selectedChange: FileChange? { files.first { $0.path == selectedPath } }
    private var unticked: [FileChange] { RollbackPlan.unticked(files: files, keep: keep) }
    private var keptCount: Int { files.count - unticked.count }

    /// Line of the current file the "Ask" action points at.
    private var placeLine: Int? {
        guard case .text(let hunks, _) = file else { return nil }
        return ChangeFocus.placeLine(in: hunks, at: focus)
    }

    var body: some View {
        Group {
            if let server, let agent {
                if server.info?.supports("changes") == true {
                    sheetBody(agent)
                } else {
                    message(L10n.Changes.updateServer)
                }
            } else {
                message(L10n.Changes.agentGone)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.surface2)
        .task(id: agentID) { await loadCheckpoints() }
        .task(id: FileLoadKey(base: base?.id, path: selectedPath)) { await loadFile() }
        .alert(L10n.Changes.rollbackConfirmTitle, isPresented: $confirmRollback) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Changes.rollbackConfirmAction, role: .destructive) { rollBackAll() }
        } message: {
            Text(L10n.Changes.rollbackConfirmMessage)
        }
    }

    // MARK: - Layout

    private func sheetBody(_ agent: Agent) -> some View {
        GeometryReader { outer in
            sheetContent(agent, width: outer.size.width)
                .frame(width: outer.size.width, height: outer.size.height)
        }
    }

    private func sheetContent(_ agent: Agent, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(agent)
            if !timeline.isEmpty {
                RestorePointStrip(
                    points: timeline, baseID: base?.id, nowTitle: L10n.Changes.now, onSelect: choose)
            }
            if let loadError {
                UserFacingErrorView(message: loadError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
            }
            if !loaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                EmptyState(
                    symbol: "doc.text.magnifyingglass",
                    title: L10n.Changes.emptyTitle,
                    message: L10n.Changes.emptyMessage)
            } else {
                // Wide: the list beside the diff. Narrow (the workbench panel): the list on top, at most 40 % of the
                // height, and the diff below it.
                GeometryReader { proxy in
                    if proxy.size.width < Self.sideBySideMinWidth {
                        VStack(spacing: 0) {
                            fileList(compact: true)
                                .frame(maxHeight: proxy.size.height * 0.4)
                            diffPane
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        HStack(spacing: 0) {
                            fileList(compact: false)
                            diffPane
                        }
                    }
                }
                footer(agent, stacked: ChangesFooterLayout.isStacked(width: width))
            }
        }
    }

    /// The compact header of the workbench tab, in two lines. The first: avatar, "Changes" and the agent's name, the
    /// diff layout on the right. The second, quiet: the file count, the lines added and removed, and the task, which is
    /// the only part cut (the whole task on hover). The tab closes the view, so there is no close button here. Narrow,
    /// the layout switch shows icons instead of words.
    private func header(_ agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentAvatarView(agent: agent, server: server, size: 20)
                Text(L10n.Changes.heading)
                    .font(BanditoFont.display(size: 15, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .fixedSize()
                Text(agent.name)
                    .font(BanditoFont.display(size: 15, weight: 600))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    SegmentedPicker(
                        selection: $viewMode,
                        options: [(.inline, L10n.Changes.inline), (.sideBySide, L10n.Changes.sideBySide)]
                    )
                    .fixedSize()
                    viewModeIcons
                }
                .layoutPriority(1)
            }
            summaryLine
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }

    /// The two layouts as icons, for a narrow panel.
    private var viewModeIcons: some View {
        HStack(spacing: 4) {
            viewModeIcon(.inline, symbol: "text.alignleft", label: L10n.Changes.inline)
            viewModeIcon(.sideBySide, symbol: "rectangle.split.2x1", label: L10n.Changes.sideBySide)
        }
    }

    private func viewModeIcon(_ mode: ChangesViewMode, symbol: String, label: String) -> some View {
        Button {
            viewMode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(viewMode == mode ? Color.Bandito.text : Color.Bandito.text3)
                .frame(width: 28, height: 28)
                .background(
                    viewMode == mode ? Color.Bandito.text.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .banditoButton(.icon(size: 28, label: label))
        .help(label)
    }

    /// "6 файлов · +412 −18 · Задача «…»" in one quiet line. The stats never cut; the task is cut with an ellipsis and
    /// shows in full on hover. The parts appear once known.
    @ViewBuilder private var summaryLine: some View {
        let task = base.flatMap(CheckpointLabel.task(for:)).map { L10n.Changes.task(task: $0) }
        if diff != nil || task != nil {
            HStack(spacing: 0) {
                if let diff {
                    Text(ChangesSummaryLine.stats(
                        files: diff.files.count, additions: diff.additions, deletions: diff.deletions))
                        .fixedSize()
                }
                if diff != nil, task != nil {
                    Text(" · ").fixedSize()
                }
                if let task {
                    Text(task)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(task)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(BanditoFont.text(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileList(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(files) { change in
                        fileRow(change)
                    }
                }
                .padding(10)
            }
            Text(L10n.Changes.keepHint)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineSpacing(2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(10)
        }
        .frame(width: compact ? nil : 320)
        .frame(maxWidth: compact ? .infinity : nil)
        .overlay(alignment: compact ? .bottom : .trailing) {
            Rectangle()
                .fill(Color.Bandito.text.opacity(0.06))
                .frame(width: compact ? nil : 1, height: compact ? 1 : nil)
                .frame(maxWidth: compact ? .infinity : nil, maxHeight: compact ? nil : .infinity)
        }
    }

    private func fileRow(_ change: FileChange) -> some View {
        let selected = change.path == selectedPath
        return HStack(spacing: 9) {
            Toggle(isOn: keepBinding(change.path)) { EmptyView() }
                .toggleStyle(.checkbox)
                .tint(Color.Bandito.signal)
                .labelsHidden()
                .accessibilityLabel(L10n.Changes.keepAria(name: Self.fileName(change.path)))
            Button { select(change.path) } label: {
                HStack(spacing: 9) {
                    FileGlyph(category: ChangedFileKind.category(path: change.path), size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(change.path)
                            .font(BanditoFont.mono(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(fileCaption(change))
                            .font(BanditoFont.text(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if let additions = change.additions {
                            Text(ChangesChips.additions(additions)).foregroundStyle(Color.Bandito.ok)
                        }
                        if let deletions = change.deletions {
                            Text(ChangesChips.deletions(deletions)).foregroundStyle(Color.Bandito.danger)
                        }
                    }
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 10))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.Bandito.text.opacity(0.06) : Color.clear)
        )
        .opacity(keep.contains(change.path) ? 1 : 0.55)
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            if let change = selectedChange {
                HStack(spacing: 10) {
                    Text(change.path)
                        .font(BanditoFont.mono(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(change.status.title)
                        .font(BanditoFont.text(size: 11.5, weight: 600))
                        .foregroundStyle(change.status.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(change.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Spacer(minLength: 8)
                    if case .text(let hunks, _) = file, !hunks.isEmpty {
                        Text(L10n.Changes.placeCount(count: hunks.count))
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
                }
                filePane()
            } else {
                message(L10n.Changes.selectFile)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func filePane() -> some View {
        switch file {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .binary:
            message(L10n.Changes.binary)
        case .failed(let failure):
            UserFacingErrorView(message: failure)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
        case .text(let hunks, let truncated):
            if hunks.isEmpty {
                message(L10n.Changes.noTextChanges)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            diffRows(hunks)
                        }
                        .padding(.vertical, 8)
                    }
                    if truncated {
                        Text(L10n.Changes.truncated)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
            }
        }
    }

    @ViewBuilder private func diffRows(_ hunks: [ChangeHunk]) -> some View {
        if viewMode == .inline {
            let active = focus ?? ChangeFocus.firstChange(in: hunks)
            ForEach(hunks.indices, id: \.self) { hunkIndex in
                HunkHeaderRow(text: hunks[hunkIndex].header)
                ForEach(hunks[hunkIndex].lines.indices, id: \.self) { lineIndex in
                    InlineLineRow(
                        line: hunks[hunkIndex].lines[lineIndex],
                        focused: active == ChangeLocation(hunk: hunkIndex, line: lineIndex),
                        reveal: Self.revealDelay(lineIndex),
                        onTap: { focus = ChangeLocation(hunk: hunkIndex, line: lineIndex) })
                }
            }
        } else {
            ForEach(Array(SideBySide.rows(from: hunks).enumerated()), id: \.offset) { index, row in
                SideBySideRowView(row: row, reveal: Self.revealDelay(index))
            }
        }
    }

    /// The actions under the list. Wide: one row, the two quiet buttons on the left, the hint and the main button on the
    /// right. Narrow: the hint, the main button full width on top, and the two quiet buttons side by side under it. When
    /// they do not fit side by side, they stack.
    private func footer(_ agent: Agent, stacked: Bool) -> some View {
        VStack(spacing: 10) {
            if stacked {
                if !unticked.isEmpty {
                    untickedHint
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                keepButton(fillsWidth: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        rollbackButton
                        askButton(agent)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        rollbackButton
                        askButton(agent)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    rollbackButton
                    askButton(agent)
                    Spacer(minLength: 12)
                    if !unticked.isEmpty {
                        untickedHint
                    }
                    keepButton(fillsWidth: false)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.Bandito.bg.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }

    private var untickedHint: some View {
        Text(L10n.Changes.unticked(count: unticked.count))
            .font(BanditoFont.text(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
    }

    private var rollbackButton: some View {
        Button(L10n.Changes.rollbackAll) { confirmRollback = true }
            .banditoButton(.quiet())
            .disabled(busy)
    }

    /// The name of the agent is in the tooltip; the label stays short so the two quiet buttons fit side by side.
    private func askButton(_ agent: Agent) -> some View {
        Button(L10n.Changes.askAgentLabel) { askAgent(agent) }
            .banditoButton(.quiet())
            .help(L10n.Changes.askAgent(name: agent.name))
            .disabled(busy || placeLine == nil)
    }

    private func keepButton(fillsWidth: Bool) -> some View {
        Button(L10n.Changes.keepFiles(count: keptCount)) { keepFiles() }
            .banditoButton(.signal(fillsWidth: fillsWidth))
            .disabled(busy)
    }

    private func message(_ text: String, tint: Color = Color.Bandito.text2) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 13, weight: 500))
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
    }

    // MARK: - Actions

    private func keepBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { keep.contains(path) },
            set: { kept in
                if kept {
                    keep.insert(path)
                } else {
                    keep.remove(path)
                }
            })
    }

    private func select(_ path: String) {
        guard path != selectedPath else { return }
        selectedPath = path
        focus = nil
        file = .loading
    }

    /// Clicking a point on the timeline makes it the base of the comparison.
    private func choose(_ point: Checkpoint) {
        guard point.id != base?.id else { return }
        base = point
    }

    private func askAgent(_ agent: Agent) {
        guard let path = selectedPath, let line = placeLine else { return }
        router.selectAgent(agent.id, on: server)
        router.pendingComposerText = L10n.Changes.askPlace(path: path, line: String(line))
        router.select(mode: .team)
        onDone()
    }

    private func keepFiles() {
        let paths = RollbackPlan.paths(files: files, keep: keep)
        guard !paths.isEmpty else {
            onDone()
            return
        }
        Task { await restore(paths: paths) }
    }

    private func rollBackAll() {
        Task { await restore(paths: nil) }
    }

    /// Puts `paths` (all files when nil) back to the base. The window then offers to undo it.
    private func restore(paths: [String]?) async {
        guard !busy, let server, let base else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await server.restore(agentID: agentID, checkpointID: base.id, paths: paths)
            if !result.restored.isEmpty {
                router.rollbackNotice = RollbackNotice(
                    server: server, agentID: agentID,
                    count: result.restored.count, undoCheckpointID: result.undo)
            }
            onDone()
        } catch {
            loadError = UserFacingError.message(for: error)
        }
    }

    // MARK: - Loading

    private func loadCheckpoints() async {
        guard let server, server.info?.supports("changes") == true else { return }
        do {
            let list = try await server.checkpoints(agentID: agentID, limit: 30)
            guard !Task.isCancelled else { return }
            checkpoints = list
            base = RestorePoints.base(in: list)
            loaded = true
        } catch {
            loadError = UserFacingError.message(for: error)
            loaded = true
        }
    }

    /// Runs when the base or the selected file changes: first the diff for the base, then the file.
    private func loadFile() async {
        guard let server, let base else {
            diff = nil
            diffBase = nil
            file = .idle
            return
        }
        if diffBase != base.id {
            await loadDiff(server: server, base: base)
            guard !Task.isCancelled else { return }
        }
        guard let path = selectedPath, let change = selectedChange else {
            file = .idle
            return
        }
        // Binary files have no line counts; their diff is not read.
        guard change.additions != nil else {
            file = .binary
            return
        }
        file = .loading
        do {
            let result = try await server.changedFile(agentID: agentID, path: path, from: base.id)
            guard !Task.isCancelled else { return }
            file = .text(hunks: UnifiedDiff.parse(result.diff), truncated: result.truncated)
        } catch {
            guard !Task.isCancelled else { return }
            file = .failed(UserFacingError.message(for: error))
        }
    }

    private func loadDiff(server: ServerModel, base: Checkpoint) async {
        do {
            let result = try await server.changesDiff(agentID: agentID, from: base.id)
            guard !Task.isCancelled else { return }
            diff = result
            diffBase = base.id
            keep = Set(result.files.map(\.id))
            if !result.files.contains(where: { $0.path == selectedPath }) {
                selectedPath = result.files.first?.path
                focus = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            diff = nil
            diffBase = nil
            loadError = UserFacingError.message(for: error)
        }
    }

    // MARK: - Helpers

    /// Rows near the top animate in one after another; rows further down appear at once.
    private static func revealDelay(_ index: Int) -> Double? {
        index < 40 ? Double(index) * 0.02 : nil
    }

    private static func fileName(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    /// The status in words under the path, or "renamed from …" for a rename.
    private func fileCaption(_ change: FileChange) -> String {
        if change.status == .renamed, let from = change.from {
            return L10n.Changes.renamedFrom(path: from)
        }
        return change.status.title
    }
}

// MARK: - File state and keys

private enum FileState {
    case idle, loading
    case text(hunks: [ChangeHunk], truncated: Bool)
    case binary
    case failed(UserFacingMessage)
}

private struct FileLoadKey: Hashable {
    var base: String?
    var path: String?
}

private extension ChangeStatus {
    var tint: Color {
        switch self {
        case .added: Color.Bandito.ok
        case .modified: Color.Bandito.signal
        case .deleted: Color.Bandito.danger
        case .renamed: Color.Bandito.info
        }
    }

    var title: String {
        switch self {
        case .added: L10n.Changes.Status.added
        case .modified: L10n.Changes.Status.modified
        case .deleted: L10n.Changes.Status.deleted
        case .renamed: L10n.Changes.Status.renamed
        }
    }
}

private extension ChangeLineKind {
    var sign: String {
        switch self {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    var signTint: Color {
        switch self {
        case .added: Color.Bandito.ok
        case .removed: Color.Bandito.danger
        case .context: Color.Bandito.text3
        }
    }

    var rowTint: Color {
        switch self {
        case .added: Color.Bandito.ok.opacity(0.10)
        case .removed: Color.Bandito.danger.opacity(0.10)
        case .context: Color.clear
        }
    }

    var textTint: Color {
        switch self {
        case .added, .context: Color.Bandito.text
        case .removed: Color.Bandito.text2
        }
    }
}

// MARK: - Subviews

/// Restore points as a row of dots, joined by a hairline. A point is a small cream dot; the current one is a larger
/// filled dot with a ring; the chosen base has a ring. Labels are cut with an ellipsis and show in full on hover. When
/// the points do not fit, the row scrolls sideways.
private struct RestorePointStrip: View {
    let points: [Checkpoint]
    let baseID: String?
    let nowTitle: String
    let onSelect: (Checkpoint) -> Void

    /// Width of one point's column. Past the width the row scrolls.
    private static let columnWidth: CGFloat = 128
    private static let dotSize: CGFloat = 16

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(scrolls: false)
            ScrollView(.horizontal, showsIndicators: false) {
                strip(scrolls: true)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 22)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }

    private func strip(scrolls: Bool) -> some View {
        let maxWidth: CGFloat = scrolls ? Self.columnWidth : .infinity
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                Button { onSelect(point) } label: {
                    pointColumn(point, selected: point.id == baseID, leadingTrack: index > 0)
                }
                .banditoButton(.row(cornerRadius: 8))
                .help(CheckpointLabel.text(for: point))
                .frame(minWidth: Self.columnWidth, maxWidth: maxWidth)
            }
            nowColumn
                .frame(minWidth: Self.columnWidth, maxWidth: maxWidth)
        }
    }

    /// A hairline piece beside a dot. Hidden where a point has no neighbour, so the line joins the points only.
    private func track(_ visible: Bool) -> some View {
        Rectangle()
            .fill(visible ? Color.Bandito.text.opacity(0.08) : Color.clear)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }

    private func pointColumn(_ point: Checkpoint, selected: Bool, leadingTrack: Bool) -> some View {
        let label = CheckpointLabel.text(for: point)
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                track(leadingTrack)
                pointDot(selected: selected)
                track(true)
            }
            Text(Self.time(point))
                .font(BanditoFont.text(size: 12.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(label)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    /// A small cream dot; the chosen base gets a ring around it.
    private func pointDot(selected: Bool) -> some View {
        ZStack {
            if selected {
                Circle()
                    .stroke(Color.Bandito.text, lineWidth: 2)
                    .frame(width: Self.dotSize, height: Self.dotSize)
            }
            Circle()
                .fill(Color.Bandito.text)
                .frame(width: 7, height: 7)
        }
        .frame(width: Self.dotSize, height: Self.dotSize)
    }

    /// The current state: a filled cream dot with a ring, a signal dot in its centre, and its name.
    private var nowColumn: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                track(true)
                ZStack {
                    Circle()
                        .stroke(Color.Bandito.text, lineWidth: 1.5)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                    Circle()
                        .fill(Color.Bandito.text)
                        .frame(width: 9, height: 9)
                    Circle()
                        .fill(Color.Bandito.signal)
                        .frame(width: 4, height: 4)
                }
                .frame(width: Self.dotSize, height: Self.dotSize)
                track(false)
            }
            Text(nowTitle)
                .font(BanditoFont.text(size: 12.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }

    private static func time(_ point: Checkpoint) -> String {
        Date(timeIntervalSince1970: TimeInterval(point.createdAt) / 1000)
            .formatted(date: .omitted, time: .shortened)
    }
}

/// Fades a row in and slides it 6 pt from the left. `nil` shows it at once (Reduce Motion, or rows far down).
private struct LineReveal: ViewModifier {
    let delay: Double?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = shown || reduceMotion || delay == nil
        content
            .opacity(visible ? 1 : 0)
            .offset(x: visible ? 0 : -6)
            .onAppear {
                guard !shown, !reduceMotion, let delay else { return }
                withAnimation(.easeOut(duration: 0.3).delay(delay)) { shown = true }
            }
    }
}

private struct HunkHeaderRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.mono(size: 11.5, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.Bandito.text.opacity(0.03))
    }
}

/// One line of the unified view: the number on the side it belongs to, the sign, the text.
private struct InlineLineRow: View {
    let line: ChangeLine
    let focused: Bool
    let reveal: Double?
    let onTap: () -> Void

    var body: some View {
        let number = line.kind == .removed ? line.oldNumber : line.newNumber
        Button(action: onTap) {
            HStack(spacing: 0) {
                Text(number.map { String($0) } ?? "")
                    .frame(width: 44, alignment: .trailing)
                    .foregroundStyle(Color.Bandito.text3.opacity(0.6))
                Text(line.kind.sign)
                    .frame(width: 22, alignment: .center)
                    .foregroundStyle(line.kind.signTint)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind.textTint)
                    .strikethrough(line.kind == .removed, color: Color.Bandito.danger.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(BanditoFont.mono(size: 12.5, weight: 400))
            .padding(.trailing, 16)
            .background(line.kind.rowTint)
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 0, hoverOpacity: 0.04))
        .overlay {
            if focused {
                Rectangle().stroke(Color.Bandito.signal.opacity(0.45), lineWidth: 1)
            }
        }
        .modifier(LineReveal(delay: reveal))
    }
}

/// A row of the side-by-side view: the old line on the left, the new one on the right.
private struct SideBySideRowView: View {
    let row: SideBySideRow
    let reveal: Double?

    var body: some View {
        switch row {
        case .hunk(let header):
            HunkHeaderRow(text: header)
        case .pair(let left, let right):
            HStack(alignment: .top, spacing: 0) {
                SideCellView(cell: left)
                Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(width: 1)
                SideCellView(cell: right)
            }
            .modifier(LineReveal(delay: reveal))
        }
    }
}

private struct SideCellView: View {
    let cell: SideCell?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(cell.map { String($0.number) } ?? "")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(Color.Bandito.text3.opacity(0.6))
            Text(cell.map { $0.text.isEmpty ? " " : $0.text } ?? " ")
                .foregroundStyle(cell?.kind.textTint ?? Color.Bandito.text)
                .strikethrough(cell?.kind == .removed, color: Color.Bandito.danger.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .font(BanditoFont.mono(size: 12.5, weight: 400))
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cell?.kind.rowTint ?? Color.clear)
    }
}

/// "What changed" feedback at the bottom of the window after a rollback: "Rolled back N files · Undo".
/// It goes away by itself after a while.
struct RollbackToast: View {
    var notice: RollbackNotice
    var onClose: () -> Void

    @State private var failure: UserFacingMessage?
    @State private var undoing = false

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.Changes.rolledBack(count: notice.count))
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
            if let failure {
                UserFacingErrorView(message: failure)
            }
            Button(L10n.Changes.undo) { undo() }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.signal)
                .disabled(undoing)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.Bandito.surface3, in: Capsule())
        .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 6)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            onClose()
        }
    }

    private func undo() {
        undoing = true
        Task {
            do {
                _ = try await notice.server.restore(agentID: notice.agentID, checkpointID: notice.undoCheckpointID)
                onClose()
            } catch {
                failure = UserFacingError.message(for: error)
                undoing = false
            }
        }
    }
}
