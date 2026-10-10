import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The file viewer: tabs of open files (Files mode only), one slim toolbar, the conflict banner, and the body for
/// the file's kind. Keys come from the keymap (context `viewer`); ⌘W closes the tab. Text saves by itself.
struct FileViewer: View {
    let server: ServerModel
    /// The tabs to show. `nil` means the Files mode's own workspace.
    var ownWorkspace: FileWorkspace?
    /// `false` inside a workbench tab: no row of tabs, no back arrow; the crumb and the menu act on the host
    /// through the closures below.
    var showsTabs: Bool
    /// The folder crumb: show this folder's list. `nil`: the Files mode shows the folder in the browser.
    var onOpenFolder: ((String) -> Void)?
    /// "Open in Files" of the menu. `nil` hides the item (the viewer is in Files already).
    var onOpenInFiles: ((String) -> Void)?
    /// A file's tab was closed inside a workbench tab: the host goes back to its list, or closes itself when
    /// nothing is left to show.
    var onFileClosed: (() -> Void)?
    @Environment(Router.self) private var router
    @Environment(Keymap.self) private var keymap
    @State private var closing: String?
    @State private var showsDiff = false
    @State private var width: CGFloat = 0

    init(
        server: ServerModel, workspace: FileWorkspace? = nil, showsTabs: Bool = true,
        onOpenFolder: ((String) -> Void)? = nil, onOpenInFiles: ((String) -> Void)? = nil,
        onFileClosed: (() -> Void)? = nil
    ) {
        self.server = server
        ownWorkspace = workspace
        self.showsTabs = showsTabs
        self.onOpenFolder = onOpenFolder
        self.onOpenInFiles = onOpenInFiles
        self.onFileClosed = onFileClosed
    }

    private var workspace: FileWorkspace { ownWorkspace ?? router.files }

    var body: some View {
        VStack(spacing: 0) {
            if showsTabs {
                ViewerTabBar(workspace: workspace, onSelect: { workspace.select($0) }, onClose: requestClose)
                    .zIndex(1)
            }
            if let document = workspace.selectedDocument {
                ViewerHeader(
                    document: document,
                    splitAllowed: ViewerLayoutRules.allowsSplit(width: width),
                    effectiveMode: ViewerLayoutRules.effectiveMode(document.mode, width: width),
                    showsBack: showsTabs,
                    onBack: { workspace.showsViewer = false },
                    onOpenFolder: openFolder,
                    onOpenInFiles: onOpenInFiles,
                    onClose: { requestClose(document.path) })
                    .zIndex(1)
                if document.conflict != nil {
                    ConflictBanner(
                        onShowDiff: { showsDiff = true },
                        onKeepMine: { Task { await document.keepMine(server: server) } },
                        onTakeServer: { document.takeServer() })
                }
                if let message = document.saveError {
                    UserFacingErrorView(message: message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                // Clipped: the content (an editor, a page or a player drawn by AppKit) cannot reach over the header
                // and the tabs, which must stay under the pointer.
                ViewerBody(
                    document: document,
                    mode: ViewerLayoutRules.effectiveMode(document.mode, width: width),
                    server: server
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .id(document.path)
            } else {
                Text(L10n.Viewer.empty)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ViewerWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(ViewerWidthKey.self) { value in
            let rounded = value.rounded()
            if rounded != width { width = rounded }
        }
        .onChange(of: workspace.tabs.selected) { old, _ in
            if let old, let document = workspace.documents[old] { Task { await document.flush() } }
        }
        .onDisappear {
            for document in workspace.documents.values { Task { await document.flush() } }
        }
        .confirmationDialog(
            L10n.Viewer.CloseUnsaved.title(name: closingName),
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Viewer.save) {
                guard let path = closing, let document = workspace.documents[path] else { return }
                closing = nil
                Task {
                    await document.save(server: server)
                    if !document.isDirty { finishClose(path) }
                }
            }
            Button(L10n.Viewer.CloseUnsaved.discard, role: .destructive) {
                if let path = closing { finishClose(path) }
                closing = nil
            }
            Button(L10n.Files.cancel, role: .cancel) { closing = nil }
        }
        .banditoSheet(isPresented: $showsDiff) {
            if let document = workspace.selectedDocument, let copy = document.conflict {
                ConflictDiffSheet(serverText: copy.text, mineText: document.text)
            }
        }
        .keymapShortcut("viewer.save", keymap: keymap) {
            if let document = workspace.selectedDocument { Task { await document.save(server: server) } }
        }
        .keymapShortcut("viewer.toggleEdit", keymap: keymap) {
            if let document = workspace.selectedDocument, document.viewer == .markdown {
                document.mode = document.mode == .read ? .edit : .read
            }
        }
        .keymapShortcut("viewer.sideBySide", keymap: keymap) {
            if let document = workspace.selectedDocument, document.viewer == .markdown,
                ViewerLayoutRules.allowsSplit(width: width)
            {
                document.mode = document.mode == .split ? .edit : .split
            }
        }
        .keymapShortcut("viewer.nextTab", keymap: keymap) { workspace.selectNext() }
        .keymapShortcut("viewer.previousTab", keymap: keymap) { workspace.selectPrevious() }
        .fixedShortcut("w", .command) {
            if let path = workspace.tabs.selected { requestClose(path) }
        }
    }

    private var closingName: String {
        closing.map { FilePath.lastComponent($0) } ?? ""
    }

    private func openFolder(_ folder: String) {
        if let onOpenFolder {
            onOpenFolder(folder)
        } else {
            router.filesPath = folder
            workspace.showsViewer = false
        }
    }

    /// Unsaved text is written first; only a save that did not work (a conflict, an error) asks the person.
    private func requestClose(_ path: String) {
        guard let document = workspace.documents[path] else { return }
        guard document.isDirty else {
            finishClose(path)
            return
        }
        Task {
            await document.flush()
            if document.isDirty { closing = path } else { finishClose(path) }
        }
    }

    private func finishClose(_ path: String) {
        workspace.close(path)
        if !showsTabs { onFileClosed?() }
    }
}

/// Rules of the viewer. Pure, so they are tested alone.
enum FileViewerRules {
    /// An empty file shows "File is empty" over the editor. Whitespace is text: a file with a single newline is not empty.
    static func showsEmptyHint(text: String) -> Bool {
        text.isEmpty
    }
}

/// How the viewer lays out for the width it has. Pure, so it is tested alone.
enum ViewerLayoutRules {
    /// Side by side needs two columns that can be read; below this width the area is too narrow for them.
    static let splitMinWidth: CGFloat = 720

    static func allowsSplit(width: CGFloat) -> Bool {
        width >= splitMinWidth
    }

    /// What is drawn: "side by side" in a narrow area shows as "edit". The document's own mode does not change,
    /// so the split returns when the area grows again.
    static func effectiveMode(_ mode: ViewerMode, width: CGFloat) -> ViewerMode {
        mode == .split && !allowsSplit(width: width) ? .edit : mode
    }
}

private struct ViewerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The row of tabs. The selected tab is raised; a dot marks unsaved text.
private struct ViewerTabBar: View {
    let workspace: FileWorkspace
    let onSelect: (String) -> Void
    let onClose: (String) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(workspace.tabs.paths, id: \.self) { path in
                if let document = workspace.documents[path] {
                    TabButton(
                        document: document,
                        isSelected: workspace.tabs.selected == path,
                        onSelect: { onSelect(path) },
                        onClose: { onClose(path) })
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44, alignment: .bottom)
        .background(Color(hex: 0x0E0C0B).opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }
}

private struct TabButton: View {
    let document: FileDocument
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    FileGlyph(category: document.category, size: 14)
                        .frame(width: 14)
                    Text(document.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    if document.needsAttention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.Bandito.signal)
                            .help(L10n.Viewer.notSaved(name: document.name))
                    } else if document.isDirty {
                        Circle().fill(Color.Bandito.signal).frame(width: 6, height: 6)
                    }
                }
            }
            .banditoButton(.row(cornerRadius: 7))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text3)
            }
            .banditoButton(.row(cornerRadius: 5, hoverOpacity: 0.08))
            .accessibilityLabel(L10n.Viewer.closeTab)
        }
        .foregroundStyle(isSelected ? Color.Bandito.text : Color.Bandito.text3)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            isSelected ? Color.Bandito.bg : .clear,
            in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
        .overlay {
            if isSelected {
                UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                    .stroke(Color.Bandito.text.opacity(0.08), lineWidth: 1)
            }
        }
    }
}

/// The one slim row of tools above a file or a folder list: crumbs on the left, icons on the right.
struct ViewerBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }
}

/// A 28 pt icon button with its tooltip.
struct ViewerIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
        }
        .banditoButton(.icon(size: 28, label: label))
    }
}

/// The "…" menu.
struct ViewerMoreMenu<Items: View>: View {
    @ViewBuilder let items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .banditoButton(.icon(size: 28, label: L10n.Viewer.moreActions))
        .fixedSize()
    }
}

/// A crumb that goes somewhere: the name of a folder.
struct ViewerCrumb: View {
    let name: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .frame(height: 24)
        }
        .banditoButton(.row(cornerRadius: 6))
        .help(help)
    }
}

/// The thin arrow between two crumbs.
struct ViewerCrumbSeparator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(Color.Bandito.text3.opacity(0.7))
            .accessibilityHidden(true)
    }
}

/// Folder › file name, the save status, the Read/Edit switch (Markdown) and the "…" menu.
private struct ViewerHeader: View {
    @Bindable var document: FileDocument
    let splitAllowed: Bool
    let effectiveMode: ViewerMode
    /// The Files mode's back arrow; a workbench tab has the folder crumb instead.
    let showsBack: Bool
    let onBack: () -> Void
    let onOpenFolder: (String) -> Void
    let onOpenInFiles: ((String) -> Void)?
    let onClose: () -> Void
    @Environment(Keymap.self) private var keymap

    private var folder: String? { FilePath.parent(of: document.path) }

    var body: some View {
        ViewerBar {
            if showsBack {
                ViewerIconButton(symbol: "chevron.left", label: L10n.Viewer.folder, action: onBack)
            }
            crumbs
        } trailing: {
            if document.viewer == .markdown {
                modeSwitch
            }
            ViewerMoreMenu {
                if let onOpenInFiles {
                    Button(L10n.Memory.Viewer.openInFiles, systemImage: "folder") { onOpenInFiles(document.path) }
                }
                Button(L10n.Files.Menu.copyPath, systemImage: "doc.on.doc") { FileBridge.copy(document.path) }
                if document.viewer == .markdown && splitAllowed {
                    Button(L10n.Viewer.Mode.split, systemImage: document.mode == .split ? "checkmark" : "rectangle.split.2x1") {
                        document.mode = document.mode == .split ? .edit : .split
                    }
                }
                if document.readOnly {
                    Divider()
                    Button(L10n.Viewer.readOnly, systemImage: "lock") {}
                        .disabled(true)
                }
                Divider()
                Button(L10n.Viewer.closeTab, systemImage: "xmark", action: onClose)
            }
        }
    }

    private var crumbs: some View {
        HStack(spacing: 4) {
            if let folder {
                ViewerCrumb(name: FilePath.lastComponent(folder), help: folder) { onOpenFolder(folder) }
                    .layoutPriority(0)
                ViewerCrumbSeparator()
            }
            Text(document.name)
                .font(BanditoFont.font(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(document.path)
                .layoutPriority(1)
            if document.readOnly {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .help(L10n.Viewer.readOnly)
                    .accessibilityLabel(L10n.Viewer.readOnly)
            }
            status
        }
    }

    /// Unsaved dot, then a spinner while it is written, then a check mark that fades away.
    private var status: some View {
        ZStack {
            if document.isSaving {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .transition(.opacity)
            } else if document.isDirty && !document.readOnly {
                Circle().fill(Color.Bandito.signal).frame(width: 6, height: 6)
                    .transition(.opacity)
            } else if document.showsSavedMark {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.Bandito.text3)
                    .transition(.opacity)
                    .accessibilityLabel(L10n.Viewer.savedStatus)
            }
        }
        .frame(width: 12, height: 12)
        .banditoAnimation(BanditoMotion.ease, value: document.isSaving)
        .banditoAnimation(BanditoMotion.ease, value: document.showsSavedMark)
        .help(document.isSaving ? L10n.Viewer.saving : "")
    }

    private func tip(_ title: String, _ command: String) -> String {
        guard let symbols = keymap.binding(for: command)?.symbols else { return title }
        return "\(title)  \(symbols)"
    }

    /// Read and Edit as two icons in one capsule. "Side by side" lives in the menu.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            modeButton(.read, symbol: "book", label: tip(L10n.Viewer.Mode.read, "viewer.toggleEdit"))
            modeButton(.edit, symbol: "pencil", label: tip(L10n.Viewer.Mode.edit, "viewer.toggleEdit"))
        }
        .padding(2)
        .background(Color.Bandito.text.opacity(0.05), in: Capsule())
        .frame(height: 26)
        .banditoAnimation(BanditoMotion.ease, value: effectiveMode)
    }

    private func modeButton(_ mode: ViewerMode, symbol: String, label: String) -> some View {
        // Side by side counts as editing: the source is on screen.
        let isSelected = (mode == .read) == (effectiveMode == .read)
        return Button {
            document.mode = mode
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.Bandito.text : Color.Bandito.text3)
                .frame(width: 28, height: 22)
                .background(isSelected ? Color.Bandito.text.opacity(0.12) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Shown when a save finds a newer copy on the server.
private struct ConflictBanner: View {
    let onShowDiff: () -> Void
    let onKeepMine: () -> Void
    let onTakeServer: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.Bandito.signal)
            Text(L10n.Viewer.Conflict.title)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(L10n.Viewer.Conflict.diff, action: onShowDiff)
                .banditoButton(.quiet())
            Button(L10n.Viewer.Conflict.keepMine, action: onKeepMine)
                .banditoButton(.quiet())
            Button(L10n.Viewer.Conflict.takeServer, action: onTakeServer)
                .banditoButton(.quiet())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.Bandito.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.signal.opacity(0.3)))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The body for the file's kind: a Markdown page or source, source text, a picture, a PDF, media, or a card.
private struct ViewerBody: View {
    let document: FileDocument
    /// The mode to draw (side by side already folded to edit in a narrow area).
    let mode: ViewerMode
    let server: ServerModel

    var body: some View {
        switch document.phase {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            UserFacingErrorView(message: message)
                .frame(maxWidth: 420)
                .padding(12)
        case .tooLarge:
            CardNote(text: L10n.Viewer.tooLarge, document: document, server: server)
                .padding(12)
        case .binary:
            CardNote(text: L10n.Viewer.Binary.title, document: document, server: server)
                .padding(12)
        case .ready:
            kindView
        }
    }

    @ViewBuilder
    private var kindView: some View {
        switch document.viewer {
        case .markdown:
            markdown
        case .text:
            editorView(highlightsMarkdown: false)
                .padding(12)
        case .image:
            ZoomableImage(path: document.path, server: server)
                .padding(12)
        case .pdf:
            RemotePDF(path: document.path, server: server)
                .padding(12)
        case .media:
            RemoteMediaPlayer(path: document.path, server: server)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(12)
        case .binary:
            CardNote(text: L10n.Viewer.Binary.title, document: document, server: server)
                .padding(12)
        }
    }

    @ViewBuilder
    private var markdown: some View {
        switch mode {
        case .read:
            MarkdownPreview(source: document.text, onToggleCheckbox: toggleCheckbox, isBare: true)
        case .edit:
            editor
                .padding(12)
        case .split:
            HStack(spacing: 12) {
                editor
                preview
            }
            .padding(12)
        }
    }

    private var editor: some View {
        editorView(highlightsMarkdown: true)
    }

    /// The source editor, with "File is empty" over it while the file has no text. An empty file takes the caret at
    /// its start (see `SourceEditor`), so typing starts at once.
    private func editorView(highlightsMarkdown: Bool) -> some View {
        SourceEditor(text: textBinding, highlightsMarkdown: highlightsMarkdown, isEditable: !document.readOnly)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topLeading) {
                if FileViewerRules.showsEmptyHint(text: document.text) {
                    Text(L10n.Viewer.emptyFile)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text3)
                        .padding(.top, 16)
                        .padding(.leading, 52)
                        .allowsHitTesting(false)
                }
            }
    }

    private var preview: some View {
        MarkdownPreview(source: document.text, onToggleCheckbox: toggleCheckbox)
    }

    private func toggleCheckbox(_ line: Int) {
        if let updated = MarkdownChecklist.toggle(document.text, line: line) {
            document.replaceText(updated)
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { document.text }, set: { document.replaceText($0) })
    }
}

/// A file the viewer cannot show: the reason, and a button to download it instead.
private struct CardNote: View {
    let text: String
    let document: FileDocument
    let server: ServerModel
    /// A download that failed: shown under the button instead of being dropped.
    @State private var failure: UserFacingMessage?

    var body: some View {
        VStack(spacing: 14) {
            FileGlyph(category: document.category, size: 56)
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Button(L10n.Files.Preview.download) {
                Task {
                    do {
                        try await FileDownload.save(document.entry, server: server)
                        failure = nil
                    } catch {
                        failure = UserFacingError.message(for: error)
                    }
                }
            }
            .banditoButton(.quiet())
            if let failure {
                UserFacingErrorView(message: failure)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A picture with pinch zoom.
private struct ZoomableImage: View {
    let path: String
    let server: ServerModel
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        RemoteImage(path: path, server: server)
            .padding(16)
            .scaleEffect(scale * pinch)
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in scale = min(max(scale * value.magnification, 0.5), 6) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A PDF from the server, through PDFKit.
private struct RemotePDF: View {
    let path: String
    let server: ServerModel
    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let data {
                PDFDocumentView(data: data)
            } else if failed {
                Text(L10n.Viewer.Media.unavailable)
                    .foregroundStyle(Color.Bandito.text2)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path) {
            do {
                data = try await RemoteFile.data(path: path, server: server)
            } catch {
                failed = true
            }
        }
    }
}

/// Lines of the server's copy and the user's copy, side by side as a list: removed in red, added in green.
private struct ConflictDiffSheet: View {
    let serverText: String
    let mineText: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = LineDiff.diff(old: serverText, new: mineText)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.Viewer.Diff.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Spacer()
                HStack(spacing: 14) {
                    Label(L10n.Viewer.Diff.server, systemImage: "minus.circle")
                        .foregroundStyle(Color.Bandito.danger)
                    Label(L10n.Viewer.Diff.mine, systemImage: "plus.circle")
                        .foregroundStyle(Color.Bandito.ok)
                }
                .font(.system(size: 12))
            }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: prefix(line.kind) + line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                            .background(background(line.kind))
                    }
                }
                .textSelection(.enabled)
            }
            .background(Color(hex: 0x0E0C0B), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Spacer()
                Button(L10n.Common.close) { dismiss() }
                    .banditoButton(.quiet())
            }
        }
        .padding(22)
        .frame(width: 640, height: 520)
        .background(Color.Bandito.surface2)
    }

    private func prefix(_ kind: DiffKind) -> String {
        switch kind {
        case .same: "  "
        case .added: "+ "
        case .removed: "− "
        }
    }

    private func color(_ kind: DiffKind) -> Color {
        switch kind {
        case .same: Color.Bandito.text2
        case .added: Color.Bandito.ok
        case .removed: Color.Bandito.danger
        }
    }

    private func background(_ kind: DiffKind) -> Color {
        switch kind {
        case .same: .clear
        case .added: Color.Bandito.ok.opacity(0.1)
        case .removed: Color.Bandito.danger.opacity(0.1)
        }
    }
}
