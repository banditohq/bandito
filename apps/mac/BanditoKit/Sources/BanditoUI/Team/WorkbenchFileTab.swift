import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Rules of the file tab (the agent's memory files and folders). Pure, so they can be tested.
enum MemoryViewerRules {
    /// One crumb of a folder list's path.
    struct Crumb: Equatable {
        var name: String
        var path: String
    }

    /// The crumbs from the tab's root folder down to `current`, each with the path it opens. A folder outside the
    /// root (it should not happen) is a single crumb of its own.
    static func crumbs(root: String, current: String) -> [Crumb] {
        func trimmed(_ path: String) -> String {
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let root = trimmed(root)
        let current = trimmed(current)
        let first = Crumb(name: FilePath.lastComponent(root), path: root)
        if current == root || current.isEmpty { return [first] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard current.hasPrefix(prefix) else { return [Crumb(name: FilePath.lastComponent(current), path: current)] }
        var result = [first]
        var path = root
        for part in current.dropFirst(prefix.count).split(separator: "/") {
            path = FilePath.join(path, String(part))
            result.append(Crumb(name: String(part), path: path))
        }
        return result
    }

    /// The folder's list: folders first, then files, each by name.
    static func sortedForList(_ entries: [FsEntry]) -> [FsEntry] {
        entries.sorted { ($0.kind == .dir ? 0 : 1, $0.name) < ($1.kind == .dir ? 0 : 1, $1.name) }
    }
}

/// A file or a folder of the server, in a workbench tab. A file opens in the file viewer; a folder lists its entries,
/// and a click on a file opens it in the same tab. The agent's memory (MEMORY.md, notes, journal, files) opens here,
/// so the person stays beside the chat. The tab's own tabs are kept here, apart from the Files mode.
struct WorkbenchFileTab: View {
    var server: ServerModel
    var agentID: String
    /// The file or folder on the server.
    var path: String

    @Environment(Router.self) private var router
    /// The file tabs of this workbench tab only: closing it leaves nothing open in the Files mode.
    @State private var workspace = FileWorkspace()
    /// Entries of the folder on show. Empty for a file.
    @State private var entries: [FsEntry] = []
    /// The folder the list shows; starts at the path itself for a folder and moves with the crumbs and clicks.
    @State private var folder = ""
    /// The first crumb: the folder the tab started with (a file's own folder, when the tab opened a single file).
    @State private var rootFolder = ""
    /// Whether the path is a folder (decided by its parent's listing) or a file.
    @State private var isFolder = false
    @State private var showingViewer = false
    @State private var error: UserFacingMessage?
    /// False until the path is known and listed: a spinner shows, not "no files".
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            if showingViewer {
                // One row of tools: the viewer's own. The folder crumb goes back to the list.
                FileViewer(
                    server: server, workspace: workspace, showsTabs: false,
                    onOpenFolder: openFolder,
                    onOpenInFiles: { router.openInFiles($0, isFile: true) },
                    onFileClosed: fileClosed)
            } else {
                listBar
                folderList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
        .task(id: "\(server.id.uuidString)|\(path)") { await resolve() }
    }

    /// The same 38 pt row as the viewer's: crumbs from the tab's root, and the "…" menu.
    private var listBar: some View {
        let crumbs = MemoryViewerRules.crumbs(root: rootFolder.isEmpty ? path : rootFolder, current: folder.isEmpty ? path : folder)
        return ViewerBar {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index == crumbs.count - 1 {
                            Text(crumb.name)
                                .font(BanditoFont.text(size: 13, weight: 600))
                                .foregroundStyle(Color.Bandito.text)
                                .lineLimit(1)
                                .padding(.horizontal, index == 0 ? 0 : 6)
                                .help(crumb.path)
                        } else {
                            ViewerCrumb(name: crumb.name, help: crumb.path) { openCrumb(crumb.path) }
                            ViewerCrumbSeparator()
                        }
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
        } trailing: {
            if let problem = workspace.documents.values.first(where: \.needsAttention) {
                // An edit that could not be written must not be forgotten: one click brings its file back.
                ViewerIconButton(
                    symbol: "exclamationmark.triangle.fill", label: L10n.Viewer.notSaved(name: problem.name)
                ) {
                    workspace.select(problem.path)
                    showingViewer = true
                }
            }
            ViewerMoreMenu {
                Button(L10n.Memory.Viewer.openInFiles, systemImage: "folder") {
                    router.openInFiles(folder.isEmpty ? path : folder, isFile: false)
                }
            }
        }
    }

    @ViewBuilder
    private var folderList: some View {
        if !loaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            UserFacingErrorView(message: error)
                .padding(16)
        } else if entries.isEmpty {
            Text(L10n.Memory.Viewer.empty)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(entries, id: \.path) { entry in
                        Button {
                            if entry.kind == .dir {
                                openCrumb(entry.path)
                            } else if entry.kind == .file {
                                openFile(entry)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.kind == .dir ? "folder" : "doc")
                                    .font(.system(size: 14))
                                    .frame(width: 18)
                                    .foregroundStyle(entry.kind == .dir ? BanditoPalette.peach : Color.Bandito.text2)
                                Text(entry.name)
                                    .font(BanditoFont.text(size: 13, weight: 400))
                                    .foregroundStyle(Color.Bandito.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .banditoButton(.row(cornerRadius: 8))
                    }
                }
                .padding(8)
            }
        }
    }

    /// Looks the path up in its parent's listing: a folder lists its entries, a file opens in the viewer.
    private func resolve() async {
        do {
            let parent = FilePath.parent(of: path) ?? path
            let listing = try await server.list(parent).entries
            if let entry = listing.first(where: { $0.path == path }), entry.kind != .dir {
                isFolder = false
                rootFolder = parent
                openFile(entry)
            } else {
                isFolder = true
                folder = path
                rootFolder = path
                showingViewer = false
                await load()
            }
            error = nil
        } catch {
            self.error = UserFacingError.message(for: error)
        }
        loaded = true
    }

    private func load() async {
        do {
            entries = MemoryViewerRules.sortedForList(try await server.list(folder).entries)
            error = nil
        } catch {
            self.error = UserFacingError.message(for: error)
        }
        loaded = true
    }

    /// Shows a folder's list in this tab (a crumb, a click on a subfolder).
    private func openCrumb(_ target: String) {
        folder = target
        Task { await load() }
    }

    /// The viewer's folder crumb: back to the list of the file's folder. A single file turns the tab into that
    /// folder's list, with the folder as its first crumb.
    private func openFolder(_ target: String) {
        if !isFolder {
            isFolder = true
            rootFolder = target
        }
        showingViewer = false
        openCrumb(target)
    }

    private func openFile(_ entry: FsEntry) {
        workspace.open(entry, server: server)
        showingViewer = true
    }

    /// A file's tab closed in the viewer: a folder's tab goes back to its list; a single file's tab closes.
    private func fileClosed() {
        if isFolder {
            showingViewer = false
        } else if workspace.tabs.paths.isEmpty {
            close()
        }
    }

    private func close() {
        router.closeWorkbenchTab(.file(path: path), agentID: agentID)
    }
}
