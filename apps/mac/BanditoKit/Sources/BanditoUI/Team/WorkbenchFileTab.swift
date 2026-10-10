import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Rules of the file tab (the agent's memory files and folders). Pure, so they can be tested.
enum MemoryViewerRules {
    /// The save button shows only when a text file has changes that can be saved, in the viewer itself.
    static func showsSave(isDirty: Bool, readOnly: Bool, showingViewer: Bool) -> Bool {
        isDirty && !readOnly && showingViewer
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
    /// The folder the list shows; starts at the path itself for a folder and moves down when a subfolder opens.
    @State private var folder = ""
    /// Folders above `folder`, for the way back.
    @State private var history: [String] = []
    /// Whether the path is a folder (decided by its parent's listing) or a file.
    @State private var isFolder = false
    @State private var showingViewer = false
    @State private var error: UserFacingMessage?
    /// False until the path is known and listed: a spinner shows, not "no files".
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.Bandito.line).frame(height: 1)
                }
            if showingViewer {
                // The header's back button goes to the folder's list, or closes the tab for a single file.
                FileViewer(server: server, workspace: workspace, onBack: isFolder ? { showingViewer = false } : close)
            } else {
                folderList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
        .task(id: "\(server.id.uuidString)|\(path)") { await resolve() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if showingViewer && isFolder {
                Button {
                    showingViewer = false
                } label: {
                    Label(L10n.Memory.Viewer.back, systemImage: "chevron.left")
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .lineLimit(1)
                        .fixedSize()
                }
                .banditoButton(.quiet())
            } else if !history.isEmpty && !showingViewer {
                Button(action: goUp) {
                    Label(L10n.Memory.Viewer.up, systemImage: "chevron.up")
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .lineLimit(1)
                        .fixedSize()
                }
                .banditoButton(.quiet())
            }
            Text(title)
                .font(BanditoFont.font(size: 14, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)
            Spacer(minLength: 8)
            if let document = workspace.selectedDocument,
                MemoryViewerRules.showsSave(isDirty: document.isDirty, readOnly: document.readOnly, showingViewer: showingViewer)
            {
                Button(L10n.Viewer.save) {
                    Task { await document.save(server: server) }
                }
                .banditoButton(.signal())
                .disabled(document.isSaving)
                .fixedSize()
            }
            Button(L10n.Memory.Viewer.openInFiles) {
                router.openInFiles(path, isFile: !isFolder)
            }
            .banditoButton(.quiet())
            .fixedSize()
        }
    }

    /// The last part of the path: the file name, or the folder name.
    private var title: String {
        let shown = showingViewer ? (workspace.selectedDocument?.path ?? path) : (folder.isEmpty ? path : folder)
        return URL(fileURLWithPath: shown).lastPathComponent
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
                .font(BanditoFont.font(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(entries, id: \.path) { entry in
                        Button {
                            if entry.kind == .dir {
                                history.append(folder)
                                folder = entry.path
                                Task { await load() }
                            } else if entry.kind == .file {
                                openFile(entry)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.kind == .dir ? "folder" : "doc")
                                    .font(.system(size: 13))
                                    .foregroundStyle(entry.kind == .dir ? BanditoPalette.peach : Color.Bandito.text2)
                                Text(entry.name)
                                    .font(BanditoFont.font(size: 13, weight: 400))
                                    .foregroundStyle(Color.Bandito.text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .banditoButton(.row(cornerRadius: 8))
                    }
                }
                .padding(10)
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
                openFile(entry)
            } else {
                isFolder = true
                folder = path
                history = []
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

    private func goUp() {
        guard let previous = history.popLast() else { return }
        folder = previous
        Task { await load() }
    }

    private func openFile(_ entry: FsEntry) {
        workspace.open(entry, server: server)
        showingViewer = true
    }

    private func close() {
        router.closeWorkbenchTab(.file(path: path), agentID: agentID)
    }
}
