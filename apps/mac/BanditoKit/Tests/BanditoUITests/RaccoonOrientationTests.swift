import AppKit
import BanditoDesign
import Testing

@testable import BanditoUI

/// The raccoon stands the way the logo does on every platform: the ears are above the eyes on the screen. The Mac host
/// is flipped like UIKit's views (y down from the top), so the same lights come out in the same places on both.
@MainActor
@Suite struct RaccoonOrientationTests {
    @Test func earsAreAboveTheEyesOnTheScreen() throws {
        let side: CGFloat = 280
        let host = RaccoonLightsNSView(reduceMotion: false, dark: true)
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        host.layoutSubtreeIfNeeded()
        let lights = try #require(host.layer as? RaccoonLightsLayer)
        lights.layoutIfNeeded()
        lights.show(at: 2.4)

        let figure = RaccoonLights.figure
        let discs = Array((lights.sublayers ?? []).prefix(figure.lights.count))
        let ear = try #require(zip(discs, figure.lights).filter { $0.1.region == .fur }.min { $0.1.y < $1.1.y })
        let eyeY = try #require(figure.eyeCentres.first).y * Double(side)

        // The screen's top-left origin: a flipped host has it at y = 0, an unflipped one at y = height.
        func screenY(_ layerY: CGFloat) -> CGFloat { host.isFlipped ? layerY : side - layerY }
        #expect(host.isFlipped, "the host is flipped, like UIKit's views")
        #expect(screenY(ear.0.position.y) < CGFloat(eyeY), "the ears are above the eyes on the screen")
    }
}
