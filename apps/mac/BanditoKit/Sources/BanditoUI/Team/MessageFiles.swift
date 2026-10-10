import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The files of a message in the thread. Pictures are shown in the thread; a click opens them in the picture viewer
/// (see `ImageViewer`). Other files are chips: a click opens the file in a tab of the workbench panel beside the chat.
struct MessageFiles: View {
    var files: [AgentAttachment]
    var agentID: String
    var server: ServerModel

    /// Optional, like the thread's: without a router a click does nothing.
    @Environment(Router.self) private var router: Router?

    var body: some View {
        let pictures = files.filter { AttachmentRules.isImage(name: $0.name) }
        let others = files.filter { !AttachmentRules.isImage(name: $0.name) }
        VStack(alignment: .trailing, spacing: 8) {
            if !pictures.isEmpty {
                PictureRows(pictures: pictures, server: server) { file in
                    openPicture(file, in: pictures)
                }
            }
            ForEach(others) { file in
                Button {
                    open(file)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.Bandito.text3)
                        Text(file.name)
                            .font(BanditoFont.font(size: 12.5, weight: 500))
                            .foregroundStyle(Color.Bandito.text2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(BanditoFont.font(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                }
                .banditoButton(.row(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.Bandito.line, lineWidth: 0.5))
                .help(file.name)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func open(_ file: AgentAttachment) {
        router?.showInWorkbench(.file(path: file.path), agentID: agentID)
    }

    /// Opens the viewer on `file`, with every picture of the message to step through.
    private func openPicture(_ file: AgentAttachment, in pictures: [AgentAttachment]) {
        let items = pictures.map { picture in
            ImageViewerItem(
                name: picture.name, source: .server(server, path: picture.path),
                openInFiles: (agentID: agentID, path: picture.path))
        }
        let index = pictures.firstIndex { $0.path == file.path } ?? 0
        router?.imageViewer = ImageViewerRequest(items: items, index: index)
    }
}

/// The pictures of a message, right-aligned. One picture keeps its proportions in a 260 × 200 box (never enlarged);
/// several are squares of 120 pt, cropped to fill, in rows of three.
private struct PictureRows: View {
    let pictures: [AgentAttachment]
    let server: ServerModel
    let onOpen: (AgentAttachment) -> Void

    /// The box one picture fits in.
    static let single = CGSize(width: 260, height: 200)
    /// The edge of each square when there are several.
    static let square: CGFloat = 120
    static let perRow = 3

    var body: some View {
        if pictures.count == 1, let picture = pictures.first {
            PictureTile(file: picture, server: server, square: nil) { onOpen(picture) }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(rows[row]) { picture in
                            PictureTile(file: picture, server: server, square: Self.square) { onOpen(picture) }
                        }
                    }
                }
            }
        }
    }

    /// The pictures cut into rows of `perRow`, in order.
    private var rows: [[AgentAttachment]] {
        stride(from: 0, to: pictures.count, by: Self.perRow).map { start in
            Array(pictures[start..<min(start + Self.perRow, pictures.count)])
        }
    }
}

/// One picture in the thread. It is read in full (the same request as `RemoteImage`). A surface-coloured box of the
/// final size stands in while it loads, and a "no picture" icon shows when it cannot be read.
private struct PictureTile: View {
    let file: AgentAttachment
    let server: ServerModel
    /// The edge of a square, or `nil` for a single picture that keeps its proportions.
    let square: CGFloat?
    let action: () -> Void

    @State private var image: NSImage?
    @State private var failed = false

    private var radius: CGFloat { square == nil ? 12 : 10 }

    /// The size of the tile: the square, or the picture fitted in the single box once it is known.
    private var frame: CGSize {
        if let square { return CGSize(width: square, height: square) }
        guard let image else { return PictureRows.single }
        let scale = ImageViewerZoom.fitScale(image: image.size, container: PictureRows.single)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.Bandito.surface2
                if let image {
                    if square == nil {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                } else if failed {
                    Image(systemName: "photo.slash")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if square == nil {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.Bandito.line, lineWidth: 0.5)
                }
            }
        }
        .banditoButton(.row(cornerRadius: radius))
        .help(file.name)
        .task(id: file.path) { await load() }
    }

    private func load() async {
        image = nil
        failed = false
        do {
            let data = try await RemoteFile.data(path: file.path, server: server)
            guard let loaded = NSImage(data: data) else { throw RemoteFile.Failure.unavailable }
            image = loaded
        } catch {
            failed = true
        }
    }
}
