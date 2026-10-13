import AppKit
import Testing

@testable import BanditoDesign
@testable import BanditoUI

extension ScreenWorkSuites {
    /// The raccoon stands the way the logo does: its ears are above its eyes on the screen, whatever view hosts the layer.
    /// The layer asks itself whether its contents run down from the top (`contentsAreFlipped`) and turns the figure's y to
    /// match. The tests check the layer's own answer and the order of its lights, in a view that is not flipped and in the
    /// Mac host. The windows are borderless, off every screen, and never shown.
    @MainActor
    @Suite struct RaccoonOrientationTests {
        private let side: CGFloat = 280

        /// The layer shown at rest, and its ear (the highest fur light) and first eye, in the layer's own y.
        private func restingEarAndEye(_ lights: RaccoonLightsLayer) throws -> (ear: CGFloat, eye: CGFloat) {
            lights.layoutIfNeeded()
            lights.show(at: 2.4)
            let figure = RaccoonLights.figure
            let discs = Array((lights.figureLayer.sublayers ?? []).prefix(figure.lights.count))
            let ear = try #require(zip(discs, figure.lights).filter { $0.1.region == .fur }.min { $0.1.y < $1.1.y })
            let eye = try #require(figure.eyeCentres.first)
            return (ear.0.position.y, CGFloat(eye.y) * RaccoonLightsLayer.referenceSide)
        }

        /// A view that is not flipped (as an ordinary window's content) hosts the layer: the layer turns the figure over
        /// so that the ears are on top, whatever the view says.
        @Test func earsStandAboveTheEyesInANonFlippedView() throws {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            let lights = RaccoonLightsLayer()
            lights.configure(
                signal: CGColor(red: 1, green: 0.5, blue: 0.2, alpha: 1),
                cream: CGColor(red: 1, green: 0.95, blue: 0.87, alpha: 1), fullStrength: false, reduceMotion: false)
            lights.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            view.layer = lights
            view.wantsLayer = true
            #expect(!view.isFlipped)
            let figure = try restingEarAndEye(lights)
            // Contents that run up: the top of the figure is the layer's high y.
            #expect(!lights.contentsAreFlipped())
            #expect(figure.ear > figure.eye, "the ears stand above the eyes: ear y \(figure.ear), eye y \(figure.eye)")
        }

        /// The Mac host, in a window: its layer runs down from the top, so the ears have the lower y.
        @Test func earsStandAboveTheEyesInTheMacHost() throws {
            let host = RaccoonLightsNSView(reduceMotion: false, dark: true)
            host.frame = NSRect(x: 0, y: 0, width: side, height: side)
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: side, height: side),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let lights = try #require(host.layer as? RaccoonLightsLayer)
            let figure = try restingEarAndEye(lights)
            #expect(lights.contentsAreFlipped())
            #expect(figure.ear < figure.eye, "the ears stand above the eyes: ear y \(figure.ear), eye y \(figure.eye)")
        }
    }
}
