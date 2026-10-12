import BanditoDesign
import SwiftUI
import UIKit

// The raccoon of points of light on iPhone: a UIView whose layer is the shared `RaccoonLightsLayer` (BanditoDesign), the
// figure and its flight. The view only resolves the brand's colours for dark and passes Reduce Motion on.

/// The lights of the raccoon in a square view. Built once per appearance; Reduce Motion draws the rest at once.
struct RaccoonLightsAssembly: UIViewRepresentable {
    let reduceMotion: Bool

    func makeUIView(context: Context) -> RaccoonLightsView {
        RaccoonLightsView(frame: .zero, reduceMotion: reduceMotion)
    }

    func updateUIView(_ view: RaccoonLightsView, context: Context) {}
}

/// A view that shows the shared lights as its own layer.
final class RaccoonLightsView: UIView {
    override class var layerClass: AnyClass { RaccoonLightsLayer.self }

    init(frame: CGRect, reduceMotion: Bool = false) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        // The onboarding is always dark: the brand's colours are resolved for dark.
        (layer as? RaccoonLightsLayer)?.configure(
            signal: Self.color(Color.Bandito.signal), cream: Self.color(Color.Bandito.text),
            fullStrength: false, reduceMotion: reduceMotion)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func color(_ base: Color) -> CGColor {
        UIColor(base)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .cgColor
    }
}
