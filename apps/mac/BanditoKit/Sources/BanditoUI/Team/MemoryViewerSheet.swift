import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// What the memory viewer opens: one file (MEMORY.md), or a folder of the agent's memory (notes, journal, files).
struct MemoryViewerTarget: Identifiable, Equatable {
    var path: String
    var isFile: Bool
    var id: String { path }
}

/// Rules of the memory viewer. Pure, so they can be tested.
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

/// The memory viewer: a sheet over the chat, so the person stays in the thread. A file opens in the file viewer; a
/// folder lists its files, and a click on a file opens it in the same sheet. "Open in Files" goes to the Files mode.
struct MemoryViewerSheet: View {
    var server: ServerModel
    var target: MemoryViewerTarget
    var onClose: () -> Void

    @Environment(Router.self) private var router
    /// The tabs of this sheet only: closing the sheet leaves nothing open in the Files mode.
    @State private var workspace = FileWorkspace()
    /// Entries of the folder on show. Empty for a single file.
    @State private var entries: [FsEntry] = []
    /// The folder the list shows; starts at the target folder and moves down when a subfolder is opened.
    @State private var folder: String
    /// Folders above `folder`, for the way back.
    @State private var history: [String] = []
    @State private var showingViewer = false
    @State private var error: UserFacingMessage?
    /// False until the first listing has answered: a spinner shows, not "no files".
    @State private var loaded = false

    init(server: ServerModel, target: MemoryViewerTarget, onClose: @escaping () -> Void) {
        self.server = server
        self.target = target
        self.onClose = onClose
        _folder = State(initialValue: target.isFile ? (FilePath.parent(of: target.path) ?? target.path) : target.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.Bandito.line).frame(height: 1)
                }
            if showingViewer {
                // The header's back button goes to the list of the folder, or closes the sheet for a single file.
                FileViewer(server: server, workspace: workspace, onBack: target.isFile ? onClose : { showingViewer = false })
            } else {
                folderList
            }
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 480, idealHeight: 600)
        .background(Color.Bandito.bg)
        .task(id: folder) { await load() }
        .task {
            // A single file opens straight away.
            if target.isFile { openFile(path: target.path) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if showingViewer && !target.isFile {
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
                .help(target.path)
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
                router.openInFiles(target.path, isFile: target.isFile)
                onClose()
            }
            .banditoButton(.quiet())
            .fixedSize()
            Button(L10n.Common.close, action: onClose)
                .banditoButton(.quiet())
                .fixedSize()
        }
    }

    /// The last part of the path: the file name, or the folder name.
    private var title: String {
        URL(fileURLWithPath: showingViewer ? (workspace.selectedDocument?.path ?? folder) : folder).lastPathComponent
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
                            } else if entry.kind == .file {
                                openFile(path: entry.path)
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
    }

    /// Opens a file in the viewer of this sheet. The file is looked up in its folder, which the sheet lists anyway.
    private func openFile(path: String) {
        Task {
            let parent = FilePath.parent(of: path) ?? folder
            do {
                let listing = try await server.list(parent).entries
                guard let entry = listing.first(where: { $0.path == path }) else { return }
                workspace.open(entry, server: server)
                showingViewer = true
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }
}
