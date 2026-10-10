import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Where the bytes of a picture come from: the server (the whole file, through the same request as `RemoteImage`),
/// a file on this Mac, or a picture already in memory (a screenshot or the clipboard).
enum ImageViewerSource {
    case server(ServerModel, path: String)
    case file(URL)
    case data(Data)
}

/// One picture the viewer can show.
struct ImageViewerItem {
    var name: String
    var source: ImageViewerSource
    /// Where the picture is in Files, for "Open in Files": the agent whose workbench shows it, and the path on the
    /// server. `nil` when the picture has no place in Files (a draft in the composer).
    var openInFiles: (agentID: String, path: String)?
}

/// The pictures to show and the one that comes first. The router holds it; while it is set, the viewer covers the
/// main window.
struct ImageViewerRequest {
    /// Tells one opening from the next: the viewer is rebuilt for each request.
    let id = UUID()
    var items: [ImageViewerItem]
    var index: Int
    /// The agent whose composer the viewer was opened from. Closing the viewer gives that composer the focus back.
    var returnFocusAgentID: String?
}

/// Reads the bytes of a picture. The server's file is the full one, not a miniature.
@MainActor
enum ImageViewerLoader {
    static func data(for source: ImageViewerSource) async throws -> Data {
        switch source {
        case .server(let server, let path):
            return try await RemoteFile.data(path: path, server: server)
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        case .data(let data):
            return data
        }
    }
}

/// The picture viewer: a full-window overlay with a dark backdrop, shown over the main window (see `MainWindow`).
///
/// The picture fits the window at first. A trackpad pinch, ⌘= and ⌘-, and the wheel with ⌘ zoom; a double-click
/// goes between fit and 100% at the click; dragging moves a picture that is bigger than the window. ← and → go to the
/// other pictures of the message. Esc, the cross and a click on the backdrop close it.
struct ImageViewer: View {
    let request: ImageViewerRequest

    @Environment(Router.self) private var router
    @State private var index: Int
    @State private var zoom = ImageViewerZoom()
    @State private var loaded: Loaded = .loading
    /// The size of the picture area, where the picture fits.
    @State private var box: CGSize = .zero
    /// The offset and the scale when a drag or a pinch started.
    @State private var panStart: CGSize?
    @State private var pinchStart: CGFloat?
    @State private var scrollMonitor: Any?
    /// The window the viewer is shown in: only its wheel events zoom.
    @State private var hostWindow: NSWindow?
    /// Why the last "Save as" failed, shown under the toolbar. `nil` when it did not fail.
    @State private var saveError: UserFacingMessage?
    @FocusState private var focused: Bool

    private enum Loaded {
        case loading
        case ready(NSImage, Data)
        case failed
    }

    /// Space the toolbar and the counter take above and below the picture.
    private static let topSpace: CGFloat = 72
    private static let bottomSpace: CGFloat = 56
    private static let sideSpace: CGFloat = 48

    init(request: ImageViewerRequest) {
        self.request = request
        _index = State(initialValue: min(max(request.index, 0), max(request.items.count - 1, 0)))
    }

    private var item: ImageViewerItem { request.items[index] }

    private var image: NSImage? {
        if case .ready(let image, _) = loaded { return image }
        return nil
    }

    /// The scale that fits the current picture in the picture area.
    private var fit: CGFloat {
        guard let image else { return 1 }
        return ImageViewerZoom.fitScale(image: image.size, container: box)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            picture
                .padding(.top, Self.topSpace)
                .padding(.bottom, Self.bottomSpace)
                .padding(.horizontal, Self.sideSpace)
            VStack(spacing: 0) {
                toolbar
                Spacer()
                if request.items.count > 1 {
                    counter
                }
            }
            if request.items.count > 1 {
                arrows
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            step(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1)
            return .handled
        }
        .task(id: index) { await load() }
        .onAppear {
            focused = true
            hostWindow = NSApp.keyWindow
            installScrollMonitor()
        }
        .onDisappear { removeScrollMonitor() }
    }

    // MARK: Picture

    @ViewBuilder
    private var picture: some View {
        switch loaded {
        case .loading:
            Color.clear
                .overlay { ProgressView().controlSize(.regular) }
                .background(boxReader)
        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "photo.slash")
                    .font(.system(size: 34, weight: .regular))
                Text(L10n.Viewer.imageFailed)
                    .font(BanditoFont.font(size: 14, weight: 400))
            }
            .foregroundStyle(Color.white.opacity(0.75))
            .background(boxReader)
        case .ready(let image, _):
            pictureView(image)
                .background(boxReader)
        }
    }

    /// The picture at its scale, centred and moved by the offset. Its own frame is the target of the double-click and
    /// the drag, so the double-click position is read in the picture's coordinates.
    private func pictureView(_ image: NSImage) -> some View {
        let scale = zoom.effectiveScale(fit: fit)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return Image(nsImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    // The point from the centre of the window: the picture centre is offset from it.
                    let anchor = CGPoint(
                        x: value.location.x - size.width / 2 + zoom.offset.width,
                        y: value.location.y - size.height / 2 + zoom.offset.height)
                    zoom.toggle(at: anchor, fit: fit)
                    settle(in: box)
                }
            )
            .simultaneousGesture(dragGesture(image: image, scale: scale))
            .simultaneousGesture(pinchGesture)
            .offset(zoom.offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dragGesture(image: NSImage, scale: CGFloat) -> some SwiftUI.Gesture {
        DragGesture()
            .onChanged { value in
                guard ImageViewerZoom.canPan(image: image.size, scale: scale, container: box) else { return }
                if panStart == nil { panStart = zoom.offset }
                let start = panStart ?? .zero
                zoom.pan(
                    to: CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height),
                    image: image.size, container: box)
            }
            .onEnded { _ in panStart = nil }
    }

    private var pinchGesture: some SwiftUI.Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = zoom.effectiveScale(fit: fit) }
                zoom.set(scale: (pinchStart ?? 1) * value.magnification, fit: fit)
                settle(in: box)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Reads the size of the picture area, the box the picture fits in.
    private var boxReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { box = proxy.size }
                .onChange(of: proxy.size) { _, size in
                    box = size
                    settle(in: size)
                }
        }
    }

    // MARK: Toolbar and navigation

    private var toolbar: some View {
        VStack(alignment: .trailing, spacing: 8) {
            buttons
            if let saveError {
                UserFacingErrorView(message: saveError)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button { zoomBy(1 / ImageViewerZoom.stepFactor) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .banditoButton(.icon(size: 30, label: L10n.Viewer.zoomOut))
            .keyboardShortcut("-", modifiers: .command)
            .disabled(image == nil)
            if image != nil {
                Text("\(ImageViewerZoom.percent(zoom.effectiveScale(fit: fit)))%")
                    .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .monospacedDigit()
                    .frame(minWidth: 44)
            }
            Button { zoomBy(ImageViewerZoom.stepFactor) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .banditoButton(.icon(size: 30, label: L10n.Viewer.zoomIn))
            .keyboardShortcut("=", modifiers: .command)
            .disabled(image == nil)
            Spacer().frame(width: 6)
            Button(L10n.Viewer.fit) { zoom.fit() }
                .banditoButton(.quiet())
            if item.openInFiles != nil {
                Button(L10n.Viewer.openInFiles) { openInFiles() }
                    .banditoButton(.quiet())
            }
            Button(L10n.Viewer.saveAs) { saveAs() }
                .banditoButton(.lightPill())
                .disabled(image == nil)
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .banditoButton(.icon(size: 30, label: L10n.Viewer.close))
        }
    }

    private var counter: some View {
        Text(L10n.Viewer.counter(n: String(index + 1), total: String(request.items.count)))
            .font(BanditoFont.font(size: 12, weight: 400, mono: true))
            .foregroundStyle(Color.white.opacity(0.8))
            .monospacedDigit()
            .padding(.bottom, 16)
    }

    private var arrows: some View {
        HStack {
            arrowButton("chevron.left", label: L10n.Common.back) { step(-1) }
                .disabled(index == 0)
            Spacer()
            arrowButton("chevron.right", label: L10n.Common.next) { step(1) }
                .disabled(index == request.items.count - 1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func arrowButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
        }
        .banditoButton(.icon(size: 36, label: label))
    }

    // MARK: Actions

    private func step(_ delta: Int) {
        let next = min(max(index + delta, 0), request.items.count - 1)
        if next != index { index = next }
    }

    private func zoomBy(_ factor: CGFloat) {
        guard image != nil else { return }
        zoom.zoom(by: factor, fit: fit)
        settle(in: box)
    }

    /// Keeps the offset inside the pan limits after the picture's size or the window's size changed.
    private func settle(in container: CGSize) {
        guard let image else { return }
        zoom.settle(image: image.size, container: container)
    }

    private func close() {
        router.imageViewer = nil
        if let agentID = request.returnFocusAgentID {
            router.requestComposerFocus(agentID: agentID)
        }
    }

    private func openInFiles() {
        guard let target = item.openInFiles else { return }
        close()
        router.showInWorkbench(.file(path: target.path), agentID: target.agentID)
    }

    private func saveAs() {
        guard case .ready(_, let data) = loaded, let url = FileBridge.saveURL(suggestedName: item.name) else { return }
        do {
            try data.write(to: url)
            saveError = nil
        } catch {
            saveError = UserFacingError.message(for: error)
        }
    }

    /// Reads the picture of the current index. A new picture starts at fit.
    private func load() async {
        loaded = .loading
        zoom = ImageViewerZoom()
        saveError = nil
        do {
            let data = try await ImageViewerLoader.data(for: item.source)
            guard !Task.isCancelled else { return }
            guard let picture = NSImage(data: data) else {
                loaded = .failed
                return
            }
            loaded = .ready(picture, data)
        } catch {
            guard !Task.isCancelled else { return }
            loaded = .failed
        }
    }

    /// ⌘ with the wheel zooms around the centre. A local monitor, because SwiftUI has no scroll-wheel modifier on macOS.
    /// Only the events of the viewer's own window count; the monitor is removed when the viewer closes.
    private func installScrollMonitor() {
        guard scrollMonitor == nil, let host = hostWindow else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === host, event.modifierFlags.contains(.command), event.scrollingDeltaY != 0 else {
                return event
            }
            zoomBy(ImageViewerZoom.scrollFactor(deltaY: event.scrollingDeltaY))
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        hostWindow = nil
    }
}
