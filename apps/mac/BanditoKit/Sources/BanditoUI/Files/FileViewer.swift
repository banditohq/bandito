import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The file viewer: tabs of open files, a header with the view mode and save, the conflict banner, and the body
/// for the file's kind. Keys come from the keymap (context `viewer`); ⌘W closes the tab.
struct FileViewer: View {
    let server: ServerModel
    @Environment(Router.self) private var router
    @Environment(Keymap.self) private var keymap
    @State private var closing: String?
    @State private var showsDiff = false

    private var workspace: FileWorkspace { router.files }

    var body: some View {
        VStack(spacing: 0) {
            ViewerTabBar(workspace: workspace, onSelect: { workspace.select($0) }, onClose: requestClose)
            if let document = workspace.selectedDocument {
                ViewerHeader(
                    document: document,
                    onBack: { workspace.showsViewer = false },
                    onSave: { Task { await document.save(server: server) } })
                if document.conflict != nil {
                    ConflictBanner(
                        onShowDiff: { showsDiff = true },
                        onKeepMine: { Task { await document.keepMine(server: server) } },
                        onTakeServer: { document.takeServer() })
                }
                if let message = document.saveError {
                    UserFacingErrorView(message: message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                ViewerBody(document: document, server: server)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    if !document.isDirty { workspace.close(path) }
                }
            }
            Button(L10n.Viewer.CloseUnsaved.discard, role: .destructive) {
                if let path = closing { workspace.close(path) }
                closing = nil
            }
            Button(L10n.Files.cancel, role: .cancel) { closing = nil }
        }
        .sheet(isPresented: $showsDiff) {
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
            if let document = workspace.selectedDocument, document.viewer == .markdown {
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

    /// A tab with unsaved text asks first; a clean tab closes at once.
    private func requestClose(_ path: String) {
        if let document = workspace.documents[path], document.isDirty {
            closing = path
        } else {
            workspace.close(path)
        }
    }
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
                    if document.isDirty {
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

/// Name, view mode (Markdown only), unsaved hint, and save and back.
private struct ViewerHeader: View {
    @Bindable var document: FileDocument
    let onBack: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Label(L10n.Viewer.folder, systemImage: "chevron.left")
                    .font(.system(size: 12.5))
            }
            .banditoButton(.quiet())
            if document.viewer == .markdown {
                Rectangle().fill(Color.Bandito.text.opacity(0.1)).frame(width: 1, height: 18)
                SegmentedPicker(
                    selection: $document.mode,
                    options: [
                        (ViewerMode.read, L10n.Viewer.Mode.read),
                        (ViewerMode.edit, L10n.Viewer.Mode.edit),
                        (ViewerMode.split, L10n.Viewer.Mode.split),
                    ])
            }
            Spacer(minLength: 8)
            if document.readOnly {
                Chip(text: L10n.Viewer.readOnly)
            }
            if document.isDirty {
                HStack(spacing: 6) {
                    Circle().fill(Color.Bandito.signal).frame(width: 6, height: 6)
                    Text(L10n.Viewer.unsaved)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            if document.viewer == .markdown || document.viewer == .text {
                Button(action: onSave) {
                    Label(L10n.Viewer.save, systemImage: "square.and.arrow.down")
                }
                .banditoButton(.lightPill())
                .disabled(!document.isDirty || document.readOnly || document.isSaving)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
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
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The body for the file's kind: a Markdown page or source, source text, a picture, a PDF, media, or a card.
private struct ViewerBody: View {
    let document: FileDocument
    let server: ServerModel

    var body: some View {
        switch document.phase {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            UserFacingErrorView(message: message)
                .frame(maxWidth: 420)
        case .tooLarge:
            CardNote(text: L10n.Viewer.tooLarge, document: document, server: server)
        case .binary:
            CardNote(text: L10n.Viewer.Binary.title, document: document, server: server)
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
            SourceEditor(text: textBinding, highlightsMarkdown: false, isEditable: !document.readOnly)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .image:
            ZoomableImage(path: document.path, server: server)
        case .pdf:
            RemotePDF(path: document.path, server: server)
        case .media:
            RemoteMediaPlayer(path: document.path, server: server)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .binary:
            CardNote(text: L10n.Viewer.Binary.title, document: document, server: server)
        }
    }

    @ViewBuilder
    private var markdown: some View {
        switch document.mode {
        case .read:
            preview
        case .edit:
            editor
        case .split:
            HStack(spacing: 12) {
                editor
                preview
            }
        }
    }

    private var editor: some View {
        SourceEditor(text: textBinding, highlightsMarkdown: true, isEditable: !document.readOnly)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var preview: some View {
        MarkdownPreview(source: document.text) { line in
            if let updated = MarkdownChecklist.toggle(document.text, line: line) {
                document.replaceText(updated)
            }
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
            .scaleEffect(scale * pinch)
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in scale = min(max(scale * value.magnification, 0.5), 6) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: 0x0E0C0B), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
