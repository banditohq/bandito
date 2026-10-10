import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// How the diff is laid out: one column, or old and new side by side.
enum ChangesViewMode: Hashable {
    case inline, sideBySide
}

/// "What changed": the files an agent changed since a restore point, their diffs, and what to do about
/// them (keep, roll back, ask the agent). Opened with ⌘⇧D. Design: docs/design/Changes.dc.html.
struct ChangesSheet: View {
    var agentID: String
    /// Called after a rollback with what it restored, so the window can offer to undo it.
    var onRolledBack: (RollbackNotice) -> Void

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

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
        .frame(minWidth: 880, idealWidth: 1100, maxWidth: .infinity, minHeight: 560, idealHeight: 740, maxHeight: .infinity)
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
                message(L10n.Changes.empty)
            } else {
                HStack(spacing: 0) {
                    fileList
                    diffPane
                }
                footer(agent)
            }
        }
    }

    private func header(_ agent: Agent) -> some View {
        HStack(spacing: 12) {
            AgentAvatar(name: agent.name, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Changes.title(name: agent.name))
                    .font(BanditoFont.font(size: 17, weight: 650))
                    .foregroundStyle(Color.Bandito.text)
                summaryLine
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            SegmentedPicker(
                selection: $viewMode,
                options: [(.inline, L10n.Changes.inline), (.sideBySide, L10n.Changes.sideBySide)]
            )
            .frame(width: 210)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text2)
                    .frame(width: 32, height: 32)
                    .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .banditoButton(.row(cornerRadius: 10, hoverOpacity: 0.08))
            .keyboardShortcut(.cancelAction)
            .help(L10n.Common.close)
            .accessibilityLabel(L10n.Common.close)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }

    /// "Task «…» · 6 files · +412 −18" (the parts appear once they are known).
    @ViewBuilder private var summaryLine: some View {
        HStack(spacing: 6) {
            if let task = base.flatMap(CheckpointLabel.task(for:)) {
                Text(L10n.Changes.task(task: task)).lineLimit(1)
                Text("·")
            }
            if let diff {
                Text(L10n.Changes.fileCount(count: diff.files.count))
                Text("·")
                Text("+\(diff.additions)").foregroundStyle(Color.Bandito.ok)
                Text("−\(diff.deletions)").foregroundStyle(Color.Bandito.danger)
            }
        }
    }

    private var fileList: some View {
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
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineSpacing(2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(10)
        }
        .frame(width: 320)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(width: 1)
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
                    StatusTag(status: change.status)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.fileName(change.path))
                            .font(BanditoFont.font(size: 13, weight: 400))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let caption = fileCaption(change) {
                            Text(caption)
                                .font(BanditoFont.font(size: 11.5, weight: 400, mono: change.status != .renamed))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if let additions = change.additions {
                            Text("+\(additions)").foregroundStyle(Color.Bandito.ok)
                        }
                        if let deletions = change.deletions {
                            Text("−\(deletions)").foregroundStyle(Color.Bandito.danger)
                        }
                    }
                    .font(BanditoFont.font(size: 11.5, weight: 400))
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
                .fill(selected ? Color.Bandito.signal.opacity(0.09) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Color.Bandito.signal.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .opacity(keep.contains(change.path) ? 1 : 0.55)
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            if let change = selectedChange {
                HStack(spacing: 10) {
                    Text(change.path)
                        .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(change.status.title)
                        .font(BanditoFont.font(size: 11.5, weight: 600))
                        .foregroundStyle(change.status.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(change.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Spacer(minLength: 8)
                    if case .text(let hunks, _) = file, !hunks.isEmpty {
                        Text(L10n.Changes.placeCount(count: hunks.count))
                            .font(BanditoFont.font(size: 12, weight: 400))
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
                            .font(BanditoFont.font(size: 12, weight: 400))
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

    private func footer(_ agent: Agent) -> some View {
        HStack(spacing: 10) {
            Button(L10n.Changes.rollbackAll) { confirmRollback = true }
                .buttonStyle(PillButtonStyle(tint: Color.Bandito.danger))
                .brandFocusRing(shape: Capsule())
                .disabled(busy)
            Button(L10n.Changes.askAgent(name: agent.name)) { askAgent(agent) }
                .buttonStyle(PillButtonStyle(tint: Color.Bandito.text))
                .brandFocusRing(shape: Capsule())
                .disabled(busy || placeLine == nil)
            Spacer(minLength: 12)
            if !unticked.isEmpty {
                Text(L10n.Changes.unticked(count: unticked.count))
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Button(L10n.Changes.keepFiles(count: keptCount)) { keepFiles() }
                .banditoButton(.signal())
                .disabled(busy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.Bandito.bg.opacity(0.6))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }

    private func message(_ text: String, tint: Color = Color.Bandito.text2) -> some View {
        Text(text)
            .font(BanditoFont.font(size: 13, weight: 500))
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
        dismiss()
    }

    private func keepFiles() {
        let paths = RollbackPlan.paths(files: files, keep: keep)
        guard !paths.isEmpty else {
            dismiss()
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
                onRolledBack(
                    RollbackNotice(
                        server: server, agentID: agentID,
                        count: result.restored.count, undoCheckpointID: result.undo))
            }
            dismiss()
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

    /// Folder of the file (with a trailing slash), or "renamed from …" for a rename.
    private func fileCaption(_ change: FileChange) -> String? {
        if change.status == .renamed, let from = change.from {
            return L10n.Changes.renamedFrom(path: from)
        }
        let folder = change.path.split(separator: "/").dropLast().joined(separator: "/")
        return folder.isEmpty ? nil : folder + "/"
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
    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        }
    }

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
        case .added: Color.Bandito.ok.opacity(0.08)
        case .removed: Color.Bandito.danger.opacity(0.08)
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

/// Restore points as a row of dots on one line. Filled when it appears; the chosen base has a ring.
private struct RestorePointStrip: View {
    let points: [Checkpoint]
    let baseID: String?
    let nowTitle: String
    let onSelect: (Checkpoint) -> Void

    @State private var filled = false
    private let dotSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                Button { onSelect(point) } label: {
                    column(point, first: index == 0, selected: point.id == baseID)
                }
                .banditoButton(.row(cornerRadius: 8))
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 6) {
                Circle()
                    .fill(Color.Bandito.signal)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.Bandito.surface2, lineWidth: 3))
                    .frame(width: dotSize, height: dotSize)
                Text(nowTitle)
                    .font(BanditoFont.font(size: 12.5, weight: 600))
                    .foregroundStyle(Color.Bandito.signal)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 16)
        .background(alignment: .topLeading) {
            GeometryReader { proxy in
                line(width: proxy.size.width)
            }
        }
        .padding(.horizontal, 30)
        .banditoAnimation(.easeOut(duration: 1.2).delay(0.4), value: filled)
        .onAppear { filled = true }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }

    /// Grey track between the dots, with a green-to-orange fill that grows from the left.
    private func line(width: CGFloat) -> some View {
        let step = width / CGFloat(points.count + 1)
        let span = width - step
        let y = 16 + dotSize / 2 - 1
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.Bandito.text.opacity(0.08))
                .frame(width: span, height: 2)
                .offset(x: step / 2, y: y)
            Rectangle()
                .fill(LinearGradient(colors: [Color.Bandito.ok, Color.Bandito.signal], startPoint: .leading, endPoint: .trailing))
                .frame(width: span, height: 2)
                .scaleEffect(x: filled ? 1 : 0, anchor: .leading)
                .offset(x: step / 2, y: y)
        }
    }

    private func column(_ point: Checkpoint, first: Bool, selected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if selected {
                    Circle()
                        .stroke(Color.Bandito.signal, lineWidth: 2)
                        .frame(width: dotSize, height: dotSize)
                }
                Circle()
                    .fill(first ? Color.Bandito.surface2 : Color.Bandito.ok)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(first ? Color.Bandito.ok : Color.Bandito.surface2, lineWidth: first ? 2 : 3))
            }
            .frame(width: dotSize, height: dotSize)
            Text(Self.time(point))
                .font(BanditoFont.font(size: 12.5, weight: 600))
                .foregroundStyle(selected ? Color.Bandito.signal : Color.Bandito.text)
            Text(CheckpointLabel.text(for: point))
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .frame(maxWidth: 160)
        }
        .contentShape(Rectangle())
    }

    private static func time(_ point: Checkpoint) -> String {
        Date(timeIntervalSince1970: TimeInterval(point.createdAt) / 1000)
            .formatted(date: .omitted, time: .shortened)
    }
}

private struct StatusTag: View {
    let status: ChangeStatus

    var body: some View {
        Text(status.letter)
            .font(BanditoFont.font(size: 11, weight: 700))
            .foregroundStyle(status.tint)
            .frame(width: 20, height: 20)
            .background(status.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel(status.title)
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
            .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
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
            .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
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
        .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cell?.kind.rowTint ?? Color.clear)
    }
}

private struct PillButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .font(BanditoFont.font(size: 13, weight: 500))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(tint.opacity(hovered ? 0.12 : 0.06)))
                .overlay(Capsule().stroke(tint.opacity(hovered ? 0.55 : 0.35), lineWidth: 1))
        }
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
                .font(BanditoFont.font(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
            if let failure {
                UserFacingErrorView(message: failure)
            }
            Button(L10n.Changes.undo) { undo() }
                .banditoButton(.link)
                .font(BanditoFont.font(size: 13, weight: 600))
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
