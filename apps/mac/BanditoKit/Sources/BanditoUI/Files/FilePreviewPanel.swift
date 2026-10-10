import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The panel on the right of the browser (320 pt): the selected entry's icon, name and properties, and its
/// actions. A file shows a short preview; a folder shows no preview, only what it is and what to do with it.
struct FilePreviewPanel: View {
    let entry: FsEntry?
    let server: ServerModel
    let onOpen: (FsEntry) -> Void
    let onDownload: (FsEntry) -> Void
    /// The server has terminals; without them the terminal action is not shown.
    let showsTerminal: Bool
    let onTerminal: (FsEntry) -> Void
    let onAgent: (FsEntry) -> Void
    /// Hides the panel. The toolbar's toggle does the same.
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry {
                EntryDetails(
                    entry: entry, server: server, onOpen: onOpen, onDownload: onDownload,
                    showsTerminal: showsTerminal, onTerminal: onTerminal, onAgent: onAgent
                )
                .id(entry.path)
                .transition(.opacity)
            } else {
                // Centered and not cut: the text wraps and keeps the panel's full height.
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click")
                        .font(.system(size: 22))
                    Text(L10n.Files.Preview.placeholder)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.Bandito.text3)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.Bandito.surface1.opacity(0.55))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(width: 1)
        }
        .overlay(alignment: .topTrailing) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .banditoButton(.icon(size: 26, label: L10n.Common.close))
                .padding(8)
            }
        }
        .banditoAnimation(.easeOut(duration: BanditoMotion.base), value: entry?.path)
    }
}

private struct EntryDetails: View {
    let entry: FsEntry
    let server: ServerModel
    let onOpen: (FsEntry) -> Void
    let onDownload: (FsEntry) -> Void
    let showsTerminal: Bool
    let onTerminal: (FsEntry) -> Void
    let onAgent: (FsEntry) -> Void

    private var category: FileCategory { FileCategory.of(entry) }

    var body: some View {
        if entry.kind == .dir {
            FolderDetails(
                entry: entry, onOpen: onOpen, showsTerminal: showsTerminal, onTerminal: onTerminal, onAgent: onAgent)
        } else {
            FileDetails(entry: entry, server: server, onOpen: onOpen, onDownload: onDownload)
        }
    }
}

/// A folder: a 56 pt icon, its name, "Folder", its properties, and the three things to do with it.
private struct FolderDetails: View {
    let entry: FsEntry
    let onOpen: (FsEntry) -> Void
    let showsTerminal: Bool
    let onTerminal: (FsEntry) -> Void
    let onAgent: (FsEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                FileGlyph(category: .folder, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(FileFormat.kind(.folder))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            VStack(spacing: 9) {
                PropertyRow(title: L10n.Files.Preview.changed, value: FileFormat.changed(ms: entry.modifiedMs))
                PropertyRow(
                    title: L10n.Files.Preview.access,
                    value: entry.readonly ? L10n.Files.Preview.readOnly : L10n.Files.Preview.readWrite)
                PropertyRow(title: L10n.Files.Preview.path, value: entry.path, mono: true, wraps: true)
            }
            .padding(.horizontal, 18)
            .font(.system(size: 12.5))

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Button(L10n.Files.Preview.open) { onOpen(entry) }
                    .banditoButton(.lightPill())
                    .frame(maxWidth: .infinity)
                if showsTerminal {
                    Button(L10n.Files.panelTerminal) { onTerminal(entry) }
                        .banditoButton(.quiet())
                        .frame(maxWidth: .infinity)
                }
                Button(L10n.Files.panelAgent) { onAgent(entry) }
                    .banditoButton(.quiet())
                    .frame(maxWidth: .infinity)
            }
            .lineLimit(1)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A file: icon, name, kind and size, a short preview, its properties, and open and download.
private struct FileDetails: View {
    let entry: FsEntry
    let server: ServerModel
    let onOpen: (FsEntry) -> Void
    let onDownload: (FsEntry) -> Void

    private var category: FileCategory { FileCategory.of(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FileGlyph(category: category, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)

            PreviewBox(entry: entry, category: category, server: server)
                .padding(.horizontal, 18)

            VStack(spacing: 9) {
                PropertyRow(title: L10n.Files.Preview.changed, value: FileFormat.changed(ms: entry.modifiedMs))
                PropertyRow(
                    title: L10n.Files.Preview.access,
                    value: entry.readonly ? L10n.Files.Preview.readOnly : L10n.Files.Preview.readWrite)
                PropertyRow(title: L10n.Files.Preview.path, value: entry.path, mono: true, wraps: true)
            }
            .padding(.horizontal, 18)
            .font(.system(size: 12.5))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(L10n.Files.Preview.open) { onOpen(entry) }
                    .banditoButton(.lightPill())
                Button(L10n.Files.Preview.download) { onDownload(entry) }
                    .banditoButton(.quiet())
            }
            .lineLimit(1)
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        FileFormat.subtitle(kind: FileFormat.kind(category), size: FileFormat.size(of: entry))
    }
}

/// The first lines of a text file, a picture, or the icon for everything else. Never taller than 260 pt.
private struct PreviewBox: View {
    let entry: FsEntry
    let category: FileCategory
    let server: ServerModel

    var body: some View {
        Group {
            switch FileTypes.viewer(for: category) {
            case .text, .markdown:
                TextSnippet(path: entry.path, server: server)
                    .frame(maxWidth: .infinity, minHeight: 170, maxHeight: FileBrowserLayout.previewMaxHeight)
            case .image:
                RemoteImage(path: entry.path, server: server)
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 170, maxHeight: FileBrowserLayout.previewMaxHeight)
            default:
                FileGlyph(category: category, size: 56)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .background(Color(hex: 0x0E0C0B), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.text.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The first 40 lines of a text file, in monospace. Larger files get a note instead.
private struct TextSnippet: View {
    let path: String
    let server: ServerModel
    @State private var lines: [String]?
    @State private var note: UserFacingMessage?

    var body: some View {
        Group {
            if let lines {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else if let note {
                UserFacingErrorView(message: note)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: FileBrowserLayout.previewMaxHeight, alignment: .top)
        .clipped()
        .task(id: path) {
            lines = nil
            note = nil
            do {
                let file = try await server.readText(path)
                lines = Array(file.content.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: false)
                    .prefix(40)
                    .map(String.init))
            } catch let error as RPCError where error.reason == "too_large" || error.reason == "binary" {
                note = UserFacingMessage(text: L10n.Files.Preview.tooLarge)
            } catch {
                note = FileErrorText.message(for: error)
            }
        }
    }
}

private struct PropertyRow: View {
    let title: String
    let value: String
    var mono = false
    /// A long value (a path) wraps onto as many lines as it needs, instead of being cut.
    var wraps = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize()
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(mono ? Color.Bandito.text2 : Color.Bandito.text)
                .lineLimit(wraps ? nil : 2)
                .truncationMode(wraps ? .tail : .middle)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}
