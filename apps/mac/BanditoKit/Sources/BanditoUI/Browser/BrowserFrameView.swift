import CoreGraphics
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The last picture of the page, and the views that show it. A frame comes many times a second; it goes straight
/// to the layers of those views, so SwiftUI does no work per frame: no state is written and no view body runs.
@MainActor
final class BrowserFrameStore {
    private(set) var image: CGImage?
    private var listeners: [UUID: (CGImage?) -> Void] = [:]

    /// Shows `image` in every listening view. The same picture again changes nothing.
    func set(_ image: CGImage?) {
        guard self.image !== image else { return }
        self.image = image
        for listener in listeners.values { listener(image) }
    }

    /// Calls `listener` with every new picture until `stopListening`. It also gets the current one at once.
    func listen(_ id: UUID, _ listener: @escaping (CGImage?) -> Void) {
        listeners[id] = listener
        listener(image)
    }

    func stopListening(_ id: UUID) {
        listeners[id] = nil
    }
}

/// The part of a picture to show, as a `contentsRect` (unit square, y counted from the bottom), so that it fills a
/// view of `view`'s shape and keeps the top of the page: cut from the bottom when the picture is taller than the
/// view, from both sides when it is wider. Pure, so the rule is easy to test. A size that is not usable gives the
/// whole picture.
enum BrowserFrameCrop {
    static func topFill(view: CGSize, picture: CGSize) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard usable(view), usable(picture) else { return whole }
        let viewAspect = view.width / view.height
        let pictureAspect = picture.width / picture.height
        if pictureAspect > viewAspect {
            let kept = viewAspect / pictureAspect
            return CGRect(x: (1 - kept) / 2, y: 0, width: kept, height: 1)
        }
        // The top of the picture is the top of the unit square: the kept strip sits at the top edge.
        let kept = pictureAspect / viewAspect
        return CGRect(x: 0, y: 1 - kept, width: 1, height: kept)
    }

    private static func usable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

#if os(macOS)
/// Draws the page picture in a layer, by the GPU. It takes no clicks.
/// By default the whole page fits the view, with the aspect kept. With `fillsFromTop` the view is filled and the
/// picture is cut from the bottom, so the top of the page stays in view (as `.aspectRatio(.fill)` aligned to the top).
struct BrowserFrameLayer: NSViewRepresentable {
    let store: BrowserFrameStore
    var fillsFromTop = false

    func makeNSView(context: Context) -> FrameView {
        FrameView(store: store, fillsFromTop: fillsFromTop)
    }

    func updateNSView(_ view: FrameView, context: Context) {
        view.use(store)
        view.setFillsFromTop(fillsFromTop)
    }

    static func dismantleNSView(_ view: FrameView, coordinator: ()) {
        view.stop()
    }

    final class FrameView: NSView {
        private var store: BrowserFrameStore
        private let id = UUID()
        private var fillsFromTop: Bool
        /// The picture now shown, to work out the crop again when the view changes size.
        private var picture: CGImage?

        init(store: BrowserFrameStore, fillsFromTop: Bool) {
            self.store = store
            self.fillsFromTop = fillsFromTop
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            layer?.magnificationFilter = .linear
            layer?.minificationFilter = .trilinear
            applyGravity()
            listen()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            layer?.contentsScale = window?.backingScaleFactor ?? 2
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            applyCrop()
        }

        func use(_ next: BrowserFrameStore) {
            guard next !== store else { return }
            store.stopListening(id)
            store = next
            listen()
        }

        func setFillsFromTop(_ on: Bool) {
            guard on != fillsFromTop else { return }
            fillsFromTop = on
            applyGravity()
            applyCrop()
        }

        func stop() {
            store.stopListening(id)
        }

        /// Fit: the layer scales the picture by its aspect ratio. Fill from the top: the crop already has the view's
        /// ratio (see `applyCrop`), so the layer only stretches the cut part over the whole view.
        private func applyGravity() {
            layer?.contentsGravity = fillsFromTop ? .resize : .resizeAspect
        }

        private func applyCrop() {
            guard let layer else { return }
            guard fillsFromTop else {
                layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                return
            }
            let size = picture.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            layer.contentsRect = BrowserFrameCrop.topFill(view: bounds.size, picture: size)
        }

        private func listen() {
            store.listen(id) { [weak self] image in
                guard let self else { return }
                // No fade between pictures.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.picture = image
                self.layer?.contents = image
                self.applyCrop()
                CATransaction.commit()
            }
        }
    }
}
#else
struct BrowserFrameLayer: View {
    let store: BrowserFrameStore
    var fillsFromTop = false

    var body: some View { Color.clear }
}
#endif
