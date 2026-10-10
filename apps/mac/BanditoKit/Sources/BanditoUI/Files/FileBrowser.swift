import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UniformTypeIdentifiers

/// The folder browser: toolbar with the path trail and search, the list or icon view, the details panel, and the
/// strip that shows uploads from this Mac. Keys come from the keymap (contexts `files`).
struct FileBrowser: View {
    let server: ServerModel
    @Environment(Router.self) private var router
    @Environment(Keymap.self) private var keymap
    @State private var model = FolderModel()
    /// The details panel as the user left it. Shown when the window is wide enough to dock it beside the list.
    @State private var previewVisible = true
    /// The details panel opened by its button in a narrow window, where it floats over the list.
    @State private var detailsOverlay = false
    /// Width of the whole browser, and of its toolbar. Measured, so the layout follows the window.
    @State private var browserWidth: CGFloat?
    @State private var nameSheet: NameSheet?
    @State private var renamingPath: String?
    @State private var renameDraft = ""
    @State private var dropTargeted = false

    /// The folder the router asks for (`~` when nothing was chosen).
    private var requested: String { router.filesPath ?? "~" }
    /// The absolute folder on screen: the listed one, or the requested one while listing fails.
    private var current: String { FilePath.expandHome(model.path ?? requested, home: model.home) }

    /// The details panel sits beside the list from this window width on; narrower, it floats over it.
    private var panelDocked: Bool {
        guard let browserWidth else { return true }
        let sidebar = router.sidebarVisible ? Sidebar.width : 0
        return FileBrowserLayout.isPanelDocked(windowWidth: browserWidth + sidebar)
    }

    private var panelShown: Bool {
        FileBrowserLayout.panelShown(docked: panelDocked, previewVisible: previewVisible, overlayOpen: detailsOverlay)
    }

    private var selectedEntry: FsEntry? {
        guard let selection = model.selection else { return nil }
        return model.visibleEntries.first { $0.path == selection }
    }

    private var thisMac: Bool {
        FilesServer.isThisMac(server.config.endpoint)
    }

    private var isMac: Bool {
        FilesServer.isMac(os: server.info?.os)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FilesToolbar(
                    model: model,
                    crumbs: FilePath.crumbs(for: current, home: model.home),
                    current: current,
                    canGoBack: router.canGoBack,
                    canGoForward: router.canGoForward,
                    showsTerminal: server.supports("terminals"),
                    detailsShown: panelShown,
                    onBack: { router.back() },
                    onForward: { router.forward() },
                    onCrumb: { router.filesPath = $0 },
                    onCopyPath: { FileBridge.copy($0) },
                    onSearchChange: { model.scheduleSearch(in: current, server: server) },
                    onTerminal: openTerminalHere,
                    onCreate: { nameSheet = $0 },
                    onToggleDetails: togglePanel)
                // Over the list (narrow window), the panel lies under the toolbar: the toolbar's toggle stays in reach.
                content
                    .overlay(alignment: .trailing) {
                        if !panelDocked && detailsOverlay {
                            detailsPanel
                                .frame(width: 320)
                                .background(Color.Bandito.bg)
                                .shadow(color: .black.opacity(0.35), radius: 18, x: -6)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
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

            // Docked: the list keeps its left edge when the panel appears or goes away.
            if panelDocked && panelShown {
                detailsPanel
                    .frame(width: 320)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BrowserWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(BrowserWidthKey.self) { browserWidth = $0 }
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: panelShown)
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: model.upload != nil)
        .task(id: requested) {
            model.selection = nil
            await model.load(requested, server: server)
            guard !Task.isCancelled else { return }
            // The folder on screen is a visit (⌘[ goes back to it), unless a step put it there. A path that is
            // still `~` (home not known yet) is not recorded: it would not match the same folder later.
            if current.hasPrefix("/") {
                router.files.arrive(at: current, serverID: server.id)
            }
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
        .onChange(of: router.refreshRequests) { Task { await model.reload(server: server) } }
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
        .banditoSheet(item: $nameSheet) { sheet in
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

    private var detailsPanel: some View {
        FilePreviewPanel(
            entry: selectedEntry, server: server, onOpen: open, onDownload: download,
            showsTerminal: server.supports("terminals"),
            onTerminal: { openTerminal(in: $0.path) }, onAgent: { createAgent(in: $0.path) },
            onClose: closePanel)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                if model.loadDenied {
                    accessNote
                } else {
                    UserFacingErrorView(message: error)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(28)
                }
            } else if model.visibleEntries.isEmpty, !model.isLoading {
                if model.searchResults != nil {
                    EmptyNote(text: L10n.Files.noResults, actionTitle: nil, action: nil)
                } else {
                    EmptyNote(text: L10n.Files.empty, actionTitle: L10n.Files.emptyCreate) { nameSheet = .folder }
                }
            } else if model.layout == .list {
                let showsSize = FileColumns.showsSize(model.visibleEntries)
                FileListHeader(showsSize: showsSize)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.visibleEntries) { entry in
                            FileRow(
                                entry: entry,
                                isSelected: model.selection == entry.path,
                                isRenaming: renamingPath == entry.path,
                                showsSize: showsSize,
                                renameDraft: $renameDraft,
                                onSelect: { model.selection = entry.path },
                                onOpen: { open(entry) },
                                onCommitRename: { commitRename(entry) },
                                onCancelRename: { renamingPath = nil }
                            )
                            .draggableFolder(entry)
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
                                .draggableFolder(entry)
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

    /// The folder cannot be read because the system or the server does not allow it. On this Mac that is the
    /// Full Disk Access setting; the Trash of a Mac is a special case with its own words.
    @ViewBuilder
    private var accessNote: some View {
        if FilePath.isMacTrash(current, home: model.home), FilesServer.isMac(os: server.info?.os) {
            AccessNote(
                symbol: "trash", title: L10n.Files.TrashBlocked.title, detail: L10n.Files.TrashBlocked.detail,
                actionTitle: thisMac ? L10n.Files.TrashBlocked.openFinder : nil,
                action: thisMac ? { FileBridge.open(URL(fileURLWithPath: current)) } : nil)
        } else {
            AccessNote(
                symbol: "lock.fill", title: L10n.Files.Access.title,
                detail: thisMac ? L10n.Files.Access.hintThisMac : L10n.Files.Access.hintServer,
                actionTitle: thisMac ? L10n.Files.Access.openSettings : nil,
                action: thisMac ? { FileBridge.openPrivacySettings() } : nil)
        }
    }

    private var truncationNote: String {
        var parts: [String] = []
        if model.truncated { parts.append(L10n.Files.truncated(count: model.visibleEntries.count)) }
        if model.skipped > 0 { parts.append(L10n.Files.skipped(count: model.skipped)) }
        return parts.joined(separator: " · ")
    }

    /// Return renames, Space toggles the details panel, arrows move the selection.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let rename = keymap.binding(for: "files.rename"), rename.matches(press), let selectedEntry {
            startRename(selectedEntry)
            return .handled
        }
        if let quickLook = keymap.binding(for: "files.quickLook"), quickLook.matches(press) {
            togglePanel()
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

    /// The context menu of an entry. Folders can be opened in a terminal, given an agent, and kept in Favorites;
    /// files can be downloaded to this Mac.
    @ViewBuilder
    private func menu(for entry: FsEntry) -> some View {
        let isFolder = entry.kind == .dir
        let isFavorite = router.files.favorites.contains(entry.path, serverID: server.id, home: model.home)
        Button { open(entry) } label: {
            Label(L10n.Files.Menu.open, systemImage: "arrow.up.forward.square")
        }
        if isFolder {
            if server.supports("terminals") {
                Button {
                    model.selection = entry.path
                    openTerminal(in: entry.path)
                } label: {
                    Label(L10n.Files.Menu.terminal, systemImage: "terminal")
                }
            }
            Button { createAgent(in: entry.path) } label: {
                Label(L10n.Files.Menu.agent, systemImage: "sparkles")
            }
            // A built-in place is already in the sidebar; it gets no favorite item.
            if !FavoritePath.isBuiltIn(entry.path, home: model.home, isMac: isMac) {
                Divider()
                Button { toggleFavorite(entry.path, isFavorite: isFavorite) } label: {
                    Label(
                        isFavorite ? L10n.Files.Menu.favoriteRemove : L10n.Files.Menu.favoriteAdd,
                        systemImage: isFavorite ? "star.slash" : "star")
                }
            }
        } else {
            Button { download(entry) } label: {
                Label(L10n.Files.Menu.download, systemImage: "arrow.down.circle")
            }
        }
        Button { FileBridge.copy(entry.path) } label: {
            Label(L10n.Files.Menu.copyPath, systemImage: "doc.on.doc")
        }
        Button { startRename(entry) } label: {
            Label(L10n.Files.Menu.rename, systemImage: "pencil")
        }
        Button { duplicate(entry) } label: {
            Label(L10n.Files.Menu.duplicate, systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) { trash(entry) } label: {
            Label(L10n.Files.Menu.trash, systemImage: "trash")
        }
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

    /// A folder for a new terminal waits in the Router only when the server has terminals; otherwise nothing
    /// is queued, because no pane would ever take it.
    private func openTerminal(in folder: String) {
        guard server.supports("terminals") else { return }
        router.openTerminalHere(folder)
    }

    private func togglePanel() {
        if panelDocked {
            previewVisible.toggle()
        } else {
            detailsOverlay.toggle()
        }
    }

    /// The panel's own close button: hides it in the mode on screen.
    private func closePanel() {
        let next = FileBrowserLayout.closed(
            docked: panelDocked, previewVisible: previewVisible, overlayOpen: detailsOverlay)
        previewVisible = next.previewVisible
        detailsOverlay = next.overlayOpen
    }

    private func toggleFavorite(_ path: String, isFavorite: Bool) {
        if isFavorite {
            router.files.favorites.remove(path, serverID: server.id, home: model.home)
        } else {
            router.files.favorites.add(path, serverID: server.id, home: model.home, isMac: isMac)
        }
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
                model.actionError = FileErrorText.message(for: error).wrapped { L10n.Files.Download.failed(error: $0) }
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

/// Folders can be dragged onto the Favorites in the sidebar. Files cannot.
private extension View {
    @ViewBuilder
    func draggableFolder(_ entry: FsEntry) -> some View {
        if entry.kind == .dir {
            self.draggable(entry.path)
        } else {
            self
        }
    }
}

/// The name prompts of the Create menu.
enum NameSheet: Identifiable, Hashable {
    case folder, file

    var id: Self { self }
}

/// Width of the browser, read from the layout so the details panel can follow the window.
private struct BrowserWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The toolbar of the browser, 52 pt high, items 32 pt high and centred: back and forward, the path trail,
/// search, the list or icon switch, terminal, details, create, and a menu for the rest.
///
/// It has three layouts and shows the first one that fits the width: full (words on the terminal and create
/// buttons), icons (those two as icons), and compact (search as a loupe that opens a popover). The search field
/// takes 200 to 360 pt; the path trail takes what is left and never less than 180 pt.
struct FilesToolbar: View {
    @Bindable var model: FolderModel
    let crumbs: [PathCrumb]
    let current: String
    let canGoBack: Bool
    let canGoForward: Bool
    /// The server has terminals. Without them the terminal item is not in the «…» menu at all.
    let showsTerminal: Bool
    let detailsShown: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onCrumb: (String) -> Void
    let onCopyPath: (String) -> Void
    let onSearchChange: () -> Void
    let onTerminal: () -> Void
    let onCreate: (NameSheet) -> Void
    let onToggleDetails: () -> Void

    @FocusState private var searchFocused: Bool
    /// The search field, shown in a popover from the loupe of the compact layout.
    @State private var searchPopover = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            layout(search: .field)
            layout(search: .loupe)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .titleBarZoomOnDoubleClick()
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
    }

    enum SearchStyle { case field, loupe }

    @ViewBuilder
    func layout(search: SearchStyle) -> some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .banditoButton(.icon(size: 32, label: L10n.Files.back))
                .help(L10n.Files.backHelp)
                .focusable(false)
                .disabled(!canGoBack)
            Button(action: onForward) { Image(systemName: "chevron.right") }
                .banditoButton(.icon(size: 32, label: L10n.Files.forward))
                .help(L10n.Files.forwardHelp)
                .focusable(false)
                .disabled(!canGoForward)

            trail

            switch search {
            case .field:
                searchField
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    .frame(height: 32)
            case .loupe:
                loupe
            }

            layoutSwitch

            Button(action: onToggleDetails) { Image(systemName: "sidebar.right") }
                .banditoButton(.icon(size: 32, label: detailsShown ? L10n.Files.hideDetails : L10n.Files.showDetails))
                .help(detailsShown ? L10n.Files.hideDetails : L10n.Files.showDetails)

            createMenu

            moreMenu
        }
    }

    /// The path trail takes the space the other items leave, at least 180 pt. The space is a spacer, and the
    /// trail is an overlay on it, so the trail's content never changes the toolbar's own layout. Its priority
    /// keeps the flexible search field from pushing the row past its measured width.
    private var trail: some View {
        Spacer(minLength: 180)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    CrumbTrailView(crumbs: crumbs, onCrumb: onCrumb, onCopy: onCopyPath)
                        .frame(width: max(proxy.size.width, 0), height: proxy.size.height, alignment: .leading)
                }
            }
            .layoutPriority(1)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text3)
            TextField(L10n.Files.searchPlaceholder, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1)
                .focused($searchFocused)
                .onChange(of: model.searchText) { onSearchChange() }
                .onExitCommand { model.clearSearch() }
        }
        .padding(.horizontal, 10)
        .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.Bandito.text.opacity(0.07)))
        .help(L10n.Files.searchHelp)
    }

    /// The compact search: a loupe that opens the field in a popover.
    private var loupe: some View {
        Button {
            searchPopover = true
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .banditoButton(.icon(size: 32, label: L10n.Files.searchButton))
        .help(L10n.Files.searchButton)
        .popover(isPresented: $searchPopover, arrowEdge: .bottom) {
            searchField
                .frame(width: 300, height: 32)
                .padding(12)
                .onAppear { searchFocused = true }
        }
    }

    private var layoutSwitch: some View {
        HStack(spacing: 2) {
            layoutButton(.list, symbol: "list.bullet", label: L10n.Files.Layout.list)
            layoutButton(.grid, symbol: "square.grid.2x2", label: L10n.Files.Layout.grid)
        }
        .padding(2)
        .frame(height: 32)
        .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private func layoutButton(_ layout: FileLayout, symbol: String, label: String) -> some View {
        Button {
            model.layout = layout
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .background(
                    model.layout == layout ? Color.Bandito.surface3 : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(model.layout == layout ? Color.Bandito.text : Color.Bandito.text3)
        }
        .banditoButton(.row(cornerRadius: 7, hoverOpacity: 0.08))
        .accessibilityLabel(label)
        .help(label)
    }

    /// Folder or file, in the quiet icon style of the toolbar.
    private var createMenu: some View {
        Menu {
            Button { onCreate(.folder) } label: {
                Label(L10n.Files.Create.folder, systemImage: "folder.badge.plus")
            }
            Button { onCreate(.file) } label: {
                Label(L10n.Files.Create.file, systemImage: "doc.badge.plus")
            }
        } label: {
            Image(systemName: "plus")
        }
        .banditoButton(.icon(size: 32, label: L10n.Files.create))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.Files.createHelp)
    }

    /// Everything that is not a button of its own: the terminal, copy the path, show hidden files, the details panel.
    private var moreMenu: some View {
        Menu {
            if showsTerminal {
                Button(action: onTerminal) {
                    Label(L10n.Files.Menu.terminal, systemImage: "terminal")
                }
            }
            Button { onCopyPath(current) } label: {
                Label(L10n.Files.Menu.copyPath, systemImage: "doc.on.doc")
            }
            Toggle(isOn: $model.showHidden) {
                Label(L10n.Files.hidden, systemImage: "eye")
            }
            Button(action: onToggleDetails) {
                Label(
                    detailsShown ? L10n.Files.hideDetails : L10n.Files.showDetails,
                    systemImage: "sidebar.right")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .banditoButton(.icon(size: 32, label: L10n.Files.more))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.Files.more)
    }
}

/// The path as a trail of buttons. A long path folds its middle into a `…` menu, in three steps, so the trail
/// keeps its start and its end; each button copies its own path from the context menu.
private struct CrumbTrailView: View {
    let crumbs: [PathCrumb]
    let onCrumb: (String) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        let layouts = CrumbTrail.layouts(count: crumbs.count)
        ViewThatFits(in: .horizontal) {
            trail(layouts[0])
            trail(layouts[1])
            trail(layouts[2])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trail(_ items: [CrumbTrailItem]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text3)
                        .padding(.horizontal, 3)
                }
                switch item {
                case .crumb(let position):
                    crumbButton(position)
                case .overflow(let hidden):
                    overflowMenu(hidden)
                }
            }
        }
        .fixedSize()
    }

    private func crumbButton(_ position: Int) -> some View {
        let crumb = crumbs[position]
        let isLast = position == crumbs.count - 1
        let isHome = crumb.title == "~"
        return Button {
            onCrumb(crumb.path)
        } label: {
            if isHome {
                Image(systemName: "house")
                    .font(.system(size: 13, weight: isLast ? .semibold : .regular))
            } else {
                Text(crumb.title)
                    .font(.system(size: 13.5, weight: isLast ? .semibold : .regular))
            }
        }
        .banditoButton(.link)
        .foregroundStyle(isLast ? Color.Bandito.text : Color.Bandito.text3)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .help(crumb.path)
        .accessibilityLabel(isHome ? L10n.Files.Places.home : crumb.title)
        .contextMenu {
            Button { onCopy(crumb.path) } label: {
                Label(L10n.Files.Menu.copyPath, systemImage: "doc.on.doc")
            }
        }
    }

    private func overflowMenu(_ hidden: [Int]) -> some View {
        Menu {
            ForEach(hidden, id: \.self) { position in
                Button(crumbs[position].title) { onCrumb(crumbs[position].path) }
            }
        } label: {
            Text("…")
                .font(.system(size: 13.5))
        }
        .banditoButton(.link)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help(L10n.Files.Crumb.more)
    }
}

/// Shown in place of the list when a folder is empty or nothing matches. An empty folder can offer the next step.
private struct EmptyNote: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .banditoButton(.quiet())
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// A folder that cannot be read: a lock (or the Trash), what the reason is, and the way out when there is one.
private struct AccessNote: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .banditoButton(.signal())
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Lines in the browser that the user can dismiss, such as a failed delete.
private struct ErrorBanner: View {
    let message: UserFacingMessage
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.Bandito.danger)
            UserFacingErrorView(message: message)
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
