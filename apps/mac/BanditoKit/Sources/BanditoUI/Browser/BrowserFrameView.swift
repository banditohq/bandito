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

#if os(macOS)
/// Draws the page picture in a layer: scaled to fit the view with the aspect kept, by the GPU. It takes no clicks.
struct BrowserFrameLayer: NSViewRepresentable {
    let store: BrowserFrameStore

    func makeNSView(context: Context) -> FrameView {
        FrameView(store: store)
    }

    func updateNSView(_ view: FrameView, context: Context) {
        view.use(store)
    }

    static func dismantleNSView(_ view: FrameView, coordinator: ()) {
        view.stop()
    }

    final class FrameView: NSView {
        private var store: BrowserFrameStore
        private let id = UUID()

        init(store: BrowserFrameStore) {
            self.store = store
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            layer?.contentsGravity = .resizeAspect
            layer?.magnificationFilter = .linear
            layer?.minificationFilter = .trilinear
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

        func use(_ next: BrowserFrameStore) {
            guard next !== store else { return }
            store.stopListening(id)
            store = next
            listen()
        }

        func stop() {
            store.stopListening(id)
        }

        private func listen() {
            store.listen(id) { [weak self] image in
                // No fade between pictures.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.layer?.contents = image
                CATransaction.commit()
            }
        }
    }
}
#else
struct BrowserFrameLayer: View {
    let store: BrowserFrameStore

    var body: some View { Color.clear }
}
#endif
