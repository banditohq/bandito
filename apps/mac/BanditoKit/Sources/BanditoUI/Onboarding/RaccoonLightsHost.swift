import AppKit
import BanditoDesign
import SwiftUI

/// The raccoon of points of light on the Mac: an NSView whose layer is the shared `RaccoonLightsLayer` (BanditoDesign).
/// The view resolves the brand's colours for dark and passes Reduce Motion on; it takes no mouse.
struct RaccoonLightsHost: NSViewRepresentable {
    let reduceMotion: Bool

    func makeNSView(context: Context) -> RaccoonLightsNSView {
        RaccoonLightsNSView(reduceMotion: reduceMotion)
    }

    func updateNSView(_ view: RaccoonLightsNSView, context: Context) {}
}

final class RaccoonLightsNSView: NSView {
    init(reduceMotion: Bool) {
        super.init(frame: .zero)
        let lights = RaccoonLightsLayer()
        lights.reduceMotion = reduceMotion
        // The onboarding is always dark: the brand's colours are resolved for dark.
        lights.signalColor = Self.cgColor(Color.Bandito.signal)
        lights.creamColor = Self.cgColor(Color.Bandito.text)
        // The figure's coordinates run down from the top, as on UIKit; the layer is flipped here, where AppKit's
        // layers run up.
        lights.isGeometryFlipped = true
        layer = lights
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    /// The colour as it looks in the dark appearance, whatever the app's appearance is.
    private static func cgColor(_ color: Color) -> CGColor {
        var resolved: CGColor?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)?.cgColor
        }
        return resolved ?? NSColor(color).cgColor
    }
}
