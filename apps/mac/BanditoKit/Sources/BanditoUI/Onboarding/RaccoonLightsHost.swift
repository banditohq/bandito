import AppKit
import BanditoDesign
import SwiftUI

/// The raccoon of points of light on the Mac: an NSView whose layer is the shared `RaccoonLightsLayer` (BanditoDesign).
/// `dark` picks the brand's signal colour of that appearance; the lights are solid in the light theme, so they are not
/// pale on a light background. The view takes no mouse.
struct RaccoonLightsHost: NSViewRepresentable {
    let reduceMotion: Bool
    let dark: Bool

    func makeNSView(context: Context) -> RaccoonLightsNSView {
        RaccoonLightsNSView(reduceMotion: reduceMotion, dark: dark)
    }

    func updateNSView(_ view: RaccoonLightsNSView, context: Context) {}
}

final class RaccoonLightsNSView: NSView {
    init(reduceMotion: Bool, dark: Bool) {
        super.init(frame: .zero)
        let lights = RaccoonLightsLayer()
        lights.reduceMotion = reduceMotion
        lights.fullStrength = !dark
        lights.signalColor = Self.cgColor(Color.Bandito.signal, dark: dark)
        // The cream sparks are the dark theme's cream; the light theme's text colour is brown, not a spark.
        lights.creamColor = Self.cgColor(Color.Bandito.text, dark: true)
        layer = lights
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Flipped, like UIKit's views: y runs down from the top, so the figure's coordinates are the same on both platforms.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    /// The colour as it looks in the given appearance, whatever the app's appearance is.
    private static func cgColor(_ color: Color, dark: Bool) -> CGColor {
        var resolved: CGColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)?.cgColor
        }
        return resolved ?? NSColor(color).cgColor
    }
}
