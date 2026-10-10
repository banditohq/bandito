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

/// The sizes of the pictures in the thread. Pure, so the layout is tested without a view.
enum PictureLayout {
    /// The box one picture fits in, when it is alone in its message.
    static let single = CGSize(width: 260, height: 200)
    /// The edge of a square: each picture when there are several, and the placeholder until a single one loads.
    static let square: CGFloat = 120
    static let perRow = 3
    /// The longest side of a miniature. Enough for the largest tile on a Retina screen.
    static let miniaturePixels = 520

    /// The frame of one tile. A single picture takes its proportions in `single`, never enlarged; until its size is
    /// known it is a square. Several pictures are always squares.
    static func frame(single isSingle: Bool, natural: CGSize?) -> CGSize {
        guard isSingle, let natural, natural.width > 0, natural.height > 0 else {
            return CGSize(width: square, height: square)
        }
        let scale = ImageViewerZoom.fitScale(image: natural, container: single)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }
}

/// The pictures of a message, right-aligned. One picture keeps its proportions in a 260 × 200 box (never enlarged);
/// several are squares of 120 pt, cropped to fill, in rows of three.
private struct PictureRows: View {
    let pictures: [AgentAttachment]
    let server: ServerModel
    let onOpen: (AgentAttachment) -> Void

    var body: some View {
        if pictures.count == 1, let picture = pictures.first {
            PictureTile(file: picture, server: server, single: true) { onOpen(picture) }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(rows[row]) { picture in
                            PictureTile(file: picture, server: server, single: false) { onOpen(picture) }
                        }
                    }
                }
            }
        }
    }

    /// The pictures cut into rows of `perRow`, in order.
    private var rows: [[AgentAttachment]] {
        stride(from: 0, to: pictures.count, by: PictureLayout.perRow).map { start in
            Array(pictures[start..<min(start + PictureLayout.perRow, pictures.count)])
        }
    }
}

/// The miniatures of the thread, by server and path, so a picture that scrolls back into view is not read again. Only
/// miniatures are kept: the whole file is read by the viewer.
@MainActor
enum ThreadPictureCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func key(server: ServerModel, path: String) -> NSString {
        "\(server.id)\n\(path)" as NSString
    }

    static func image(for key: NSString) -> NSImage? {
        images.object(forKey: key)
    }

    static func store(_ image: NSImage, for key: NSString) {
        images.setObject(image, forKey: key)
    }
}

/// A miniature decoded off the main thread. CGImage is not Sendable in the SDK; it is only handed back once.
private struct Miniature: @unchecked Sendable {
    let image: CGImage
}

/// One picture in the thread. A miniature of at most `PictureLayout.miniaturePixels` is decoded off the main thread
/// and cached. A square stands in while it loads, and a "no picture" icon shows when it cannot be read.
private struct PictureTile: View {
    let file: AgentAttachment
    let server: ServerModel
    /// A picture alone in its message keeps its proportions; several are squares.
    let single: Bool
    let action: () -> Void

    @State private var image: NSImage?
    @State private var failed = false

    private var radius: CGFloat { single ? 12 : 10 }

    private var frame: CGSize {
        PictureLayout.frame(single: single, natural: image?.size)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.Bandito.surface2
                if let image {
                    if single {
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
                if single {
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
        let key = ThreadPictureCache.key(server: server, path: file.path)
        if let cached = ThreadPictureCache.image(for: key) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        do {
            let data = try await RemoteFile.data(path: file.path, server: server)
            let decoded = await Task.detached(priority: .utility) { () -> Miniature? in
                Thumbnail.decode(data, maxPixel: PictureLayout.miniaturePixels).map(Miniature.init)
            }.value
            guard !Task.isCancelled else { return }
            guard let cg = decoded?.image else { throw RemoteFile.Failure.unavailable }
            let picture = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            ThreadPictureCache.store(picture, for: key)
            image = picture
        } catch is CancellationError {
            // The row scrolled away or the message changed: not a failure, and nothing to show.
            return
        } catch {
            if Task.isCancelled { return }
            failed = true
        }
    }
}
