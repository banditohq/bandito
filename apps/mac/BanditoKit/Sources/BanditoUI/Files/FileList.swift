import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Column titles above the list. The name takes the rest of the width; the date and size take what they need.
/// The size column is there only when some entry is a file (`FileColumns.showsSize`).
struct FileListHeader: View {
    let showsSize: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(L10n.Files.Column.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.Files.Column.changed)
                .fixedSize()
                .frame(minWidth: FileColumns.changedMinWidth, alignment: .leading)
            if showsSize {
                Text(L10n.Files.Column.size)
                    .fixedSize()
                    .frame(minWidth: FileColumns.sizeMinWidth, alignment: .trailing)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color.Bandito.text3)
        .lineLimit(1)
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
    }
}

/// One entry in the list: icon and name (or the rename field), when it changed, and size for files.
/// Folders have no size, so their size cell is empty.
struct FileRow: View {
    let entry: FsEntry
    let isSelected: Bool
    let isRenaming: Bool
    let showsSize: Bool
    @Binding var renameDraft: String
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                FileGlyph(category: FileCategory.of(entry), size: 28)
                if isRenaming {
                    TextField(L10n.Files.Column.name, text: $renameDraft)
                        .banditoField()
                        .focused($renameFocused)
                        .onSubmit(onCommitRename)
                        .onExitCommand(perform: onCancelRename)
                        .onAppear { renameFocused = true }
                } else {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(FileFormat.changed(ms: entry.modifiedMs))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: FileColumns.changedMinWidth, alignment: .leading)
            if showsSize {
                // Folders have no size: a dash in the quiet color, as Finder shows it.
                Text(FileFormat.sizeCell(of: entry))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(entry.kind == .dir ? Color.Bandito.text3 : Color.Bandito.text2)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: FileColumns.sizeMinWidth, alignment: .trailing)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(entry.hidden ? Color.Bandito.text3 : Color.Bandito.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.Bandito.signal.opacity(0.10) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.Bandito.signal.opacity(0.35), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .rowHighlight(cornerRadius: 10)
        .onTapGesture(count: 2) { if !isRenaming { onOpen() } }
        .onTapGesture { if !isRenaming { onSelect() } }
    }
}

/// One entry in the icon view.
struct FileTile: View {
    let entry: FsEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            FileGlyph(category: FileCategory.of(entry), size: 48)
            Text(entry.name)
                .font(.system(size: 12.5))
                .foregroundStyle(entry.hidden ? Color.Bandito.text3 : Color.Bandito.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(width: 112, height: 116)
        .background(
            isSelected ? Color.Bandito.signal.opacity(0.10) : .clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.Bandito.signal.opacity(0.35), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .rowHighlight(cornerRadius: 12)
    }
}

/// The strip above the bottom edge while a file is copied from this Mac: name, count, and a striped bar.
struct UploadStrip: View {
    let job: UploadJob
    let folder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.Files.Upload.title(name: job.name, folder: FilePath.lastComponent(folder)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(L10n.Files.Upload.count(done: String(job.index), total: String(job.total)))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.Bandito.signal)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.Bandito.text.opacity(0.08))
                    Capsule()
                        .fill(Color.Bandito.signal)
                        .frame(width: proxy.size.width * max(0, min(job.fraction, 1)))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.Bandito.signal.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.Bandito.signal.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
