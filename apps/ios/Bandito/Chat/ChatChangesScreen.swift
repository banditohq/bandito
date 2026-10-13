import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The files an agent changed, with the lines added and removed in each; a press opens the file's diff.
struct ChatChangesScreen: View {
    let server: ServerModel
    let agentID: String

    private enum Load {
        case loading
        case loaded(ChangesDiff)
        case failed
    }

    @State private var load = Load.loading

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                message(L10n.Ios.Chat.Changes.failed)
            case .loaded(let diff):
                if diff.files.isEmpty {
                    message(L10n.Changes.emptyTitle)
                } else {
                    list(diff)
                }
            }
        }
        .background(Color.Bandito.bg.ignoresSafeArea())
        .navigationTitle(L10n.Changes.heading)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            load = .loaded(try await server.changesDiff(agentID: agentID))
        } catch {
            if case .loading = load { load = .failed }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 14.5))
            .foregroundStyle(Color.Bandito.text2)
            .multilineTextAlignment(.center)
            .padding(BanditoSpace.s6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ diff: ChangesDiff) -> some View {
        List {
            Section {
                ForEach(diff.files) { file in
                    NavigationLink {
                        ChatFileDiffScreen(server: server, agentID: agentID, file: file)
                    } label: {
                        ChatChangedFileRow(file: file)
                    }
                    .listRowBackground(Color.Bandito.surface1)
                    .accessibilityIdentifier("chat.changes.file")
                }
            } header: {
                Text(ChangesSummaryLine.stats(files: diff.files.count, additions: diff.additions, deletions: diff.deletions))
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

/// A changed file: its status, its name and folder, and the counts.
struct ChatChangedFileRow: View {
    let file: FileChange

    var body: some View {
        HStack(spacing: BanditoSpace.s3) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(BanditoFont.text(size: 15, weight: 550))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: BanditoSpace.s2)
            if file.additions != nil || file.deletions != nil {
                HStack(spacing: 6) {
                    Text(ChangesChips.additions(file.additions ?? 0)).foregroundStyle(Color.Bandito.ok)
                    Text(ChangesChips.deletions(file.deletions ?? 0)).foregroundStyle(Color.Bandito.danger)
                }
                .font(BanditoFont.mono(size: 12.5, weight: 500))
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var name: String { (file.path as NSString).lastPathComponent }
    private var folder: String {
        let dir = (file.path as NSString).deletingLastPathComponent
        return dir.isEmpty ? status : dir + " · " + status
    }
    private var status: String {
        switch file.status {
        case .added: L10n.Changes.Status.added
        case .modified: L10n.Changes.Status.modified
        case .deleted: L10n.Changes.Status.deleted
        case .renamed: L10n.Changes.Status.renamed
        }
    }
    private var symbol: String {
        switch file.status {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        }
    }
    private var tint: Color {
        switch file.status {
        case .added: Color.Bandito.ok
        case .modified: Color.Bandito.info
        case .deleted: Color.Bandito.danger
        case .renamed: Color.Bandito.text2
        }
    }
}

/// The diff of one file: hunks with line numbers, added lines green and removed lines red. Wide lines scroll sideways.
struct ChatFileDiffScreen: View {
    let server: ServerModel
    let agentID: String
    let file: FileChange

    private enum Load {
        case loading
        case loaded(hunks: [ChangeHunk], truncated: Bool)
        case failed
    }

    @State private var load = Load.loading

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                Text(L10n.Ios.Chat.Diff.failed)
                    .font(BanditoFont.text(size: 14.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                    .padding(BanditoSpace.s6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let hunks, let truncated):
                if hunks.isEmpty {
                    Text(file.additions == nil ? L10n.Changes.binary : L10n.Changes.noTextChanges)
                        .font(BanditoFont.text(size: 14.5))
                        .foregroundStyle(Color.Bandito.text2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    diff(hunks, truncated: truncated)
                }
            }
        }
        .background(Color.Bandito.bg.ignoresSafeArea())
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let result = try await server.changedFile(agentID: agentID, path: file.path)
                load = .loaded(hunks: UnifiedDiff.parse(result.diff), truncated: result.truncated)
            } catch {
                load = .failed
            }
        }
    }

    private func diff(_ hunks: [ChangeHunk], truncated: Bool) -> some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                    Text(hunk.header)
                        .font(BanditoFont.mono(size: 11.5, weight: 500))
                        .foregroundStyle(Color.Bandito.info)
                        .padding(.horizontal, BanditoSpace.s3)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.Bandito.surface1)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        ChatDiffLine(line: line)
                    }
                }
                if truncated {
                    Text(L10n.Changes.truncated)
                        .font(BanditoFont.text(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                        .padding(BanditoSpace.s3)
                }
            }
            .frame(minWidth: UIScreen.main.bounds.width, alignment: .leading)
        }
    }
}

private struct ChatDiffLine: View {
    let line: ChangeLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number)
                .font(BanditoFont.mono(size: 11, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 6)
            Text(marker)
                .font(BanditoFont.mono(size: 12.5, weight: 600))
                .foregroundStyle(markerColor)
                .frame(width: 14)
            Text(line.text.isEmpty ? " " : line.text)
                .font(BanditoFont.mono(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, BanditoSpace.s3)
        }
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var number: String {
        (line.kind == .removed ? line.oldNumber : line.newNumber).map(String.init) ?? ""
    }
    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }
    private var markerColor: Color {
        switch line.kind {
        case .added: Color.Bandito.ok
        case .removed: Color.Bandito.danger
        case .context: Color.Bandito.text3
        }
    }
    private var background: Color {
        switch line.kind {
        case .added: Color.Bandito.ok.opacity(0.12)
        case .removed: Color.Bandito.danger.opacity(0.12)
        case .context: Color.clear
        }
    }
}
