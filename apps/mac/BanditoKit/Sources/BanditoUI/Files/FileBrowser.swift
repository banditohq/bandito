import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UniformTypeIdentifiers

/// The folder browser: toolbar with breadcrumbs and search, the list or icon view, the preview panel, and the
/// strip that shows uploads from this Mac. Keys come from the keymap (contexts `files`).
struct FileBrowser: View {
    let server: ServerModel
    @Environment(Router.self) private var router
    @Environment(Keymap.self) private var keymap
    @State private var model = FolderModel()
    @State private var previewVisible = true
    @State private var nameSheet: NameSheet?
    @State private var renamingPath: String?
    @State private var renameDraft = ""
    @State private var dropTargeted = false

    /// The folder the router asks for (`~` when nothing was chosen).
    private var requested: String { router.filesPath ?? "~" }
    /// The absolute folder on screen, once the server has resolved it.
    private var current: String { model.path ?? requested }

    private var selectedEntry: FsEntry? {
        guard let selection = model.selection else { return nil }
        return model.visibleEntries.first { $0.path == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                BrowserToolbar(
                    model: model,
                    crumbs: model.path.map { FilePath.crumbs(for: $0, home: model.home) } ?? [],
                    canGoBack: router.canGoBack,
                    canGoForward: router.canGoForward,
                    onBack: { router.back() },
                    onForward: { router.forward() },
                    onCrumb: { router.filesPath = $0 },
                    onSearchChange: { model.scheduleSearch(in: current, server: server) },
                    onCopyPath: { FileBridge.copy(current) },
                    onTerminal: openTerminalHere,
                    onCreate: { nameSheet = $0 })
                content
                if let job = model.upload {
                    UploadStrip(job: job, folder: current)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let message = model.actionError {
                    ErrorBanner(message: message) { model.actionError = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if previewVisible {
                FilePreviewPanel(entry: selectedEntry, server: server, onOpen: open, onDownload: download)
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: previewVisible)
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: model.upload != nil)
        .task(id: requested) {
            model.selection = nil
            await model.load(requested, server: server)
            if router.filesPath != model.path, requested == "~", let path = model.path {
                router.filesPath = path
            }
            // The folder is listed now: a file asked for (Inspector → Memory) opens, or is dropped if it is gone.
            if let path = router.takePendingFilePath(), let entry = model.visibleEntries.first(where: { $0.path == path }) {
                router.files.open(entry, server: server)
            }
        }
        .onChange(of: router.pendingFilePath) { _, path in
            // The folder may already be on screen; open the file now if it is listed. Otherwise the load opens it.
            guard let path, let entry = model.visibleEntries.first(where: { $0.path == path }) else { return }
            _ = router.takePendingFilePath()
            router.files.open(entry, server: server)
        }
        .onChange(of: model.showHidden) { Task { await model.reload(server: server) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            let folder = current
            Task {
                let urls = await Self.droppedURLs(providers)
                await model.uploadFiles(urls, into: folder, server: server)
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.signal, style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $nameSheet) { sheet in
            FileNameSheet(sheet: sheet, existing: Set(model.entries.map(\.name))) { name in
                Task {
                    switch sheet {
                    case .folder: await model.createFolder(named: name, in: current, server: server)
                    case .file: await model.createFile(named: name, in: current, server: server)
                    }
                }
            }
        }
        .confirmationDialog(
            L10n.Files.Conflict.title(name: model.uploadConflict?.name ?? ""),
            isPresented: Binding(
                get: { model.uploadConflict != nil },
                set: { if !$0 { Task { await model.resolveUploadConflict(.cancel, server: server) } } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Files.Conflict.replace, role: .destructive) {
                Task { await model.resolveUploadConflict(.replace, server: server) }
            }
            Button(L10n.Files.Conflict.keepBoth) {
                Task { await model.resolveUploadConflict(.keepBoth, server: server) }
            }
            Button(L10n.Files.cancel, role: .cancel) {
                Task { await model.resolveUploadConflict(.cancel, server: server) }
            }
        }
        .fixedShortcut(".", [.command, .shift]) { model.showHidden.toggle() }
        .keymapShortcut("files.open", keymap: keymap) { if let selectedEntry { open(selectedEntry) } }
        .keymapShortcut("files.enclosingFolder", keymap: keymap) { goUp() }
        .keymapShortcut("files.newFolder", keymap: keymap) { nameSheet = .folder }
        .keymapShortcut("files.newFile", keymap: keymap) { nameSheet = .file }
        .keymapShortcut("files.trash", keymap: keymap) { if let selectedEntry { trash(selectedEntry) } }
        .keymapShortcut("files.duplicate", keymap: keymap) { if let selectedEntry { duplicate(selectedEntry) } }
        .keymapShortcut("files.copyPath", keymap: keymap) { if let selectedEntry { FileBridge.copy(selectedEntry.path) } }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                EmptyNote(text: error)
            } else if model.visibleEntries.isEmpty, !model.isLoading {
                EmptyNote(text: model.searchResults != nil ? L10n.Files.noResults : L10n.Files.empty)
            } else if model.layout == .list {
                FileListHeader()
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.visibleEntries) { entry in
                            FileRow(
                                entry: entry,
                                isSelected: model.selection == entry.path,
                                isRenaming: renamingPath == entry.path,
                                renameDraft: $renameDraft,
                                onSelect: { model.selection = entry.path },
                                onOpen: { open(entry) },
                                onCommitRename: { commitRename(entry) },
                                onCancelRename: { renamingPath = nil }
                            )
                            .contextMenu { menu(for: entry) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                        ForEach(model.visibleEntries) { entry in
                            FileTile(entry: entry, isSelected: model.selection == entry.path)
                                .onTapGesture(count: 2) { open(entry) }
                                .onTapGesture { model.selection = entry.path }
                                .contextMenu { menu(for: entry) }
                        }
                    }
                    .padding(16)
                }
            }
            if model.truncated || model.skipped > 0 {
                Text(truncationNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .onTapGesture { model.selection = nil }
    }

    private var truncationNote: String {
        var parts: [String] = []
        if model.truncated { parts.append(L10n.Files.truncated(count: model.visibleEntries.count)) }
        if model.skipped > 0 { parts.append(L10n.Files.skipped(count: model.skipped)) }
        return parts.joined(separator: " · ")
    }

    /// Return renames, Space toggles the preview, arrows move the selection.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let rename = keymap.binding(for: "files.rename"), rename.matches(press), let selectedEntry {
            startRename(selectedEntry)
            return .handled
        }
        if let quickLook = keymap.binding(for: "files.quickLook"), quickLook.matches(press) {
            previewVisible.toggle()
            return .handled
        }
        guard press.modifiers.isEmpty, press.key == .downArrow || press.key == .upArrow else { return .ignored }
        let entries = model.visibleEntries
        guard !entries.isEmpty else { return .ignored }
        let index = entries.firstIndex { $0.path == model.selection } ?? -1
        let next = press.key == .downArrow ? min(index + 1, entries.count - 1) : max(index - 1, 0)
        model.selection = entries[next].path
        return .handled
    }

    // MARK: Menu

    /// The context menu of a row, in the order of the mockup.
    @ViewBuilder
    private func menu(for entry: FsEntry) -> some View {
        Button(L10n.Files.Menu.open) { open(entry) }
        Button(L10n.Files.Menu.terminal) {
            model.selection = entry.path
            openTerminal(in: entry.kind == .dir ? entry.path : (FilePath.parent(of: entry.path) ?? current))
        }
        Button(L10n.Files.Menu.agent) { createAgent(in: entry.kind == .dir ? entry.path : current) }
        Divider()
        Button(L10n.Files.Menu.rename) { startRename(entry) }
        Button(L10n.Files.Menu.duplicate) { duplicate(entry) }
        Button(L10n.Files.Menu.copyPath) { FileBridge.copy(entry.path) }
        if entry.kind == .file {
            Button(L10n.Files.Menu.download) { download(entry) }
        }
        Divider()
        Button(L10n.Files.Menu.trash, role: .destructive) { trash(entry) }
    }

    // MARK: Actions

    /// Folders are entered, files open in the viewer.
    private func open(_ entry: FsEntry) {
        switch entry.kind {
        case .dir:
            router.filesPath = entry.path
        case .file:
            router.files.open(entry, server: server)
        case .symlink, .other:
            model.selection = entry.path
        }
    }

    private func goUp() {
        guard let parent = FilePath.parent(of: current) else { return }
        router.filesPath = parent
    }

    private func openTerminalHere() {
        openTerminal(in: current)
    }

    private func openTerminal(in folder: String) {
        router.pendingTerminalCwd = folder
        router.select(mode: .terminals)
    }

    private func createAgent(in folder: String) {
        router.pendingAgentCwd = folder
        router.sheet = .newAgent
    }

    private func startRename(_ entry: FsEntry) {
        renameDraft = entry.name
        renamingPath = entry.path
    }

    private func commitRename(_ entry: FsEntry) {
        let name = renameDraft
        renamingPath = nil
        Task { await model.rename(entry, to: name, server: server) }
    }

    private func duplicate(_ entry: FsEntry) {
        Task { await model.duplicate(entry, server: server) }
    }

    private func trash(_ entry: FsEntry) {
        Task { await model.trash(entry, server: server) }
    }

    private func download(_ entry: FsEntry) {
        Task {
            do {
                try await FileDownload.save(entry, server: server)
            } catch {
                model.actionError = L10n.Files.Download.failed(error: FileErrorText.message(for: error))
            }
        }
    }

    /// Reads the files dropped from Finder. Anything that is not a file URL is ignored.
    private static func droppedURLs(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url, url.isFileURL { urls.append(url) }
        }
        return urls
    }
}

/// The name prompts of the Create menu.
enum NameSheet: Identifiable, Hashable {
    case folder, file

    var id: Self { self }
}

/// The toolbar of the browser: history, breadcrumbs, copy path, search, view switch, terminal, create.
private struct BrowserToolbar: View {
    @Bindable var model: FolderModel
    let crumbs: [PathCrumb]
    let canGoBack: Bool
    let canGoForward: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onCrumb: (String) -> Void
    let onSearchChange: () -> Void
    let onCopyPath: () -> Void
    let onTerminal: () -> Void
    let onCreate: (NameSheet) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .banditoButton(.icon(size: 30, label: L10n.Files.back))
                .focusable(false)
                .disabled(!canGoBack)
            Button(action: onForward) { Image(systemName: "chevron.right") }
                .banditoButton(.icon(size: 30, label: L10n.Files.forward))
                .focusable(false)
                .disabled(!canGoForward)

            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    let isLast = index == crumbs.count - 1
                    Button(crumb.title) { onCrumb(crumb.path) }
                        .banditoButton(.link)
                        .font(.system(size: 13.5, weight: isLast ? .semibold : .regular))
                        .foregroundStyle(isLast ? Color.Bandito.text : Color.Bandito.text3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 4)

            Button(action: onCopyPath) { Image(systemName: "doc.on.doc") }
                .banditoButton(.icon(size: 26, label: L10n.Files.copyPath))

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                TextField(
                    L10n.Files.search(folder: model.path.map { FilePath.lastComponent($0) } ?? ""), text: $model.searchText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onChange(of: model.searchText) { onSearchChange() }
                .onExitCommand { model.clearSearch() }
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 30)
            .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.Bandito.text.opacity(0.07)))

            HStack(spacing: 2) {
                layoutButton(.list, symbol: "list.bullet", label: L10n.Files.Layout.list)
                layoutButton(.grid, symbol: "square.grid.2x2", label: L10n.Files.Layout.grid)
            }
            .padding(2)
            .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

            Button(action: onTerminal) {
                Label(L10n.Files.terminalHere, systemImage: "terminal")
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 6)
            }
            .banditoButton(.quiet())

            Menu {
                Button(L10n.Files.Create.folder) { onCreate(.folder) }
                Button(L10n.Files.Create.file) { onCreate(.file) }
            } label: {
                Label(L10n.Files.create, systemImage: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.Bandito.onSignal)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        LinearGradient(
                            colors: [Color.Bandito.signalFill, Color.Bandito.signalFillEnd], startPoint: .top,
                            endPoint: .bottom),
                        in: Capsule())
            }
            .menuStyle(.button)
            .banditoButton(.brighten)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
    }

    private func layoutButton(_ layout: FileLayout, symbol: String, label: String) -> some View {
        Button {
            model.layout = layout
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .background(
                    model.layout == layout ? Color.Bandito.surface3 : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(model.layout == layout ? Color.Bandito.text : Color.Bandito.text3)
        }
        .banditoButton(.row(cornerRadius: 7, hoverOpacity: 0.08))
        .accessibilityLabel(label)
    }
}

/// Shown in place of the list when a folder cannot be read or is empty.
private struct EmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.Bandito.text2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}

/// Lines in the browser that the user can dismiss, such as a failed delete.
private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.Bandito.danger)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text)
            Spacer(minLength: 8)
            Button(L10n.Files.Banner.dismiss, action: dismiss)
                .banditoButton(.quiet(size: .regular))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.Bandito.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

extension FilePath {
    /// The last part of a path (`/srv/api` → `api`), or `~` for the home folder.
    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }
}
