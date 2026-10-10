import CoreGraphics
import Foundation

/// The zoom of the picture viewer: "fit" (the picture inside the window, never enlarged past 100%) or a manual scale.
/// Pure, so the rules are tested without a window.
///
/// A scale is relative to the picture's own size in points, so 100% is the size the picture has in Preview. An
/// offset moves the picture away from the centre of the window, in points. The view passes the fit scale in, because
/// it depends on the size of the window.
struct ImageViewerZoom: Equatable {
    static let minScale: CGFloat = 0.25
    static let maxScale: CGFloat = 8
    /// One step of ⌘= and ⌘-.
    static let stepFactor: CGFloat = 1.25

    enum Mode: Equatable {
        case fit, manual
    }

    private(set) var mode: Mode = .fit
    /// The manual scale. Only read in manual mode.
    private(set) var scale: CGFloat = 1
    /// Where the picture's centre sits, from the centre of the window. Zero in fit mode.
    private(set) var offset: CGSize = .zero

    /// The scale that fits `image` in `container`, at most 100%: a small picture is not enlarged. A tall or wide picture
    /// is fitted on its long side. Without a size to fit into (or with an empty picture) the answer is 100%.
    static func fitScale(image: CGSize, container: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return 1 }
        return min(1, container.width / image.width, container.height / image.height)
    }

    /// A manual scale kept in range. The lower bound is 25%, or the fit scale when the fit is smaller (a very tall
    /// picture is fitted below 25%, and can be zoomed out from there, never past its fit).
    static func clamp(_ value: CGFloat, fit: CGFloat) -> CGFloat {
        min(max(value, min(minScale, fit)), maxScale)
    }

    /// The percentage the viewer shows for a scale.
    static func percent(_ scale: CGFloat) -> Int {
        Int((scale * 100).rounded())
    }

    /// The zoom factor of one wheel movement with ⌘ held. Capped so a fast flick does not jump across the range.
    static func scrollFactor(deltaY: CGFloat) -> CGFloat {
        let limited = min(max(deltaY, -50), 50)
        return CGFloat(pow(1.01, Double(limited)))
    }

    /// Dragging moves the picture only when it is bigger than the window in some direction.
    static func canPan(image: CGSize, scale: CGFloat, container: CGSize) -> Bool {
        image.width * scale > container.width || image.height * scale > container.height
    }

    /// The scale on screen: the fit scale in fit mode, the manual one otherwise.
    func effectiveScale(fit: CGFloat) -> CGFloat {
        mode == .fit ? fit : scale
    }

    /// "Fit": the picture goes back into the window, centred.
    mutating func fit() {
        mode = .fit
        offset = .zero
    }

    /// Sets a manual scale (kept in range). The picture point under `anchor` stays under it, so a zoom at the cursor
    /// keeps the cursor on the same spot. `anchor` is measured from the centre of the window.
    mutating func set(scale target: CGFloat, fit: CGFloat, anchor: CGPoint = .zero) {
        let current = effectiveScale(fit: fit)
        let next = Self.clamp(target, fit: fit)
        let ratio = current > 0 ? next / current : 1
        offset = CGSize(
            width: anchor.x - (anchor.x - offset.width) * ratio,
            height: anchor.y - (anchor.y - offset.height) * ratio)
        scale = next
        mode = .manual
    }

    /// ⌘= and ⌘-, and the wheel with ⌘: one multiplication of the current scale.
    mutating func zoom(by factor: CGFloat, fit: CGFloat, anchor: CGPoint = .zero) {
        set(scale: effectiveScale(fit: fit) * factor, fit: fit, anchor: anchor)
    }

    /// Double-click: fit goes to 100% at the click, and anything else goes back to fit.
    mutating func toggle(at anchor: CGPoint, fit: CGFloat) {
        if mode == .fit {
            set(scale: 1, fit: fit, anchor: anchor)
        } else {
            self.fit()
        }
    }

    /// Moves the picture to `offset`. Ignored in fit mode, where the picture is centred.
    mutating func pan(to offset: CGSize) {
        guard mode == .manual else { return }
        self.offset = offset
    }
}
