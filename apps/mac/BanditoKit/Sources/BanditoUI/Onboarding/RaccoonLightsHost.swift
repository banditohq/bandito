import AppKit
import BanditoDesign
import SwiftUI

/// The raccoon of points of light on the Mac: an NSView whose layer is the shared `RaccoonLightsLayer` (BanditoDesign).
/// `dark` picks the brand's signal colour of that appearance; the lights are solid in the light theme, so they are not
/// pale on a light background. The view takes no mouse. A change of `dark` or `reduceMotion` reaches an open screen.
struct RaccoonLightsHost: NSViewRepresentable {
    let reduceMotion: Bool
    let dark: Bool

    func makeNSView(context: Context) -> RaccoonLightsNSView {
        RaccoonLightsNSView(reduceMotion: reduceMotion, dark: dark)
    }

    func updateNSView(_ view: RaccoonLightsNSView, context: Context) {
        view.apply(reduceMotion: reduceMotion, dark: dark)
    }
}

final class RaccoonLightsNSView: NSView {
    private let lights = RaccoonLightsLayer()
    private var reduceMotion: Bool
    private var dark: Bool

    init(reduceMotion: Bool, dark: Bool) {
        self.reduceMotion = reduceMotion
        self.dark = dark
        super.init(frame: .zero)
        // The layer is the view's own: it is flipped by the layer itself (`RaccoonLightsLayer`), not by the view's flag.
        layer = lights
        wantsLayer = true
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Flipped, like UIKit's views (the layer is flipped too, in the shared layer): the figure's coordinates are the same.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }

    /// Applies a change of theme or Reduce Motion to the figure on screen.
    func apply(reduceMotion: Bool, dark: Bool) {
        guard reduceMotion != self.reduceMotion || dark != self.dark else { return }
        self.reduceMotion = reduceMotion
        self.dark = dark
        configure()
    }

    override func layout() {
        super.layout()
        // The figure is built at the first layout with a size; a resize keeps it (`RaccoonLightsLayer`). Counted here,
        // so the work budget sees a figure built again.
        let before = lights.buildCount
        lights.layoutIfNeeded()
        if lights.buildCount != before { PerfCounters.hit("RaccoonLights.build") }
    }

    private func configure() {
        // The onboarding is always dark except in the light theme: the cream sparks are the dark theme's cream in both
        // (the light theme's text colour is brown, not a spark).
        lights.configure(
            signal: Self.cgColor(Color.Bandito.signal, dark: dark),
            cream: Self.cgColor(Color.Bandito.text, dark: true),
            fullStrength: !dark, reduceMotion: reduceMotion)
    }

    /// The colour as it looks in the given appearance, whatever the app's appearance is.
    private static func cgColor(_ color: Color, dark: Bool) -> CGColor {
        var resolved: CGColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)?.cgColor
        }
        return resolved ?? NSColor(color).cgColor
    }
}
