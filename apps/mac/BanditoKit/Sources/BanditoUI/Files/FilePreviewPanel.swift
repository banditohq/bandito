import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The panel on the right of the browser (360 pt): the selected file's icon, name, a short preview, its
/// properties, and the two actions. Space toggles it.
struct FilePreviewPanel: View {
    let entry: FsEntry?
    let server: ServerModel
    let onOpen: (FsEntry) -> Void
    let onDownload: (FsEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry {
                EntryDetails(entry: entry, server: server, onOpen: onOpen, onDownload: onDownload)
                    .id(entry.path)
                    .transition(.opacity)
            } else {
                Text(L10n.Files.Preview.placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.Bandito.surface1.opacity(0.55))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(width: 1)
        }
        .banditoAnimation(.easeOut(duration: BanditoMotion.base), value: entry?.path)
    }
}

private struct EntryDetails: View {
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
                PropertyRow(title: L10n.Files.Preview.path, value: entry.path, mono: true)
            }
            .padding(.horizontal, 18)
            .font(.system(size: 12.5))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(L10n.Files.Preview.open) { onOpen(entry) }
                    .buttonStyle(LightPillButtonStyle())
                if entry.kind == .file {
                    Button(L10n.Files.Preview.download) { onDownload(entry) }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        if entry.kind == .dir { return FileFormat.kind(category) }
        return "\(FileFormat.kind(category)) · \(FileFormat.size(of: entry))"
    }
}

/// The first lines of a text file, a picture, or the icon for everything else.
private struct PreviewBox: View {
    let entry: FsEntry
    let category: FileCategory
    let server: ServerModel

    var body: some View {
        Group {
            switch FileTypes.viewer(for: category) {
            case .text, .markdown:
                TextSnippet(path: entry.path, server: server)
            case .image:
                RemoteImage(path: entry.path, server: server)
                    .padding(10)
            default:
                FileGlyph(category: category, size: 56)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 210, alignment: .topLeading)
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
    @State private var note: String?

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
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: 210, alignment: .top)
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
                note = L10n.Files.Preview.tooLarge
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(mono ? Color.Bandito.text2 : Color.Bandito.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}
