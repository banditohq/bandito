import BanditoKit
import CoreGraphics
import Testing

@testable import BanditoUI

@Suite struct AvatarCropLayoutTests {
    private let image = CGSize(width: 400, height: 300)

    @Test func fullZoomFillsTheFrameWithTheShortSide() {
        let placement = AvatarCropLayout.placement(crop: AvatarCrop(), imageSize: image, frame: 300)
        #expect(placement == AvatarCropLayout.Placement(scale: 1, offset: CGPoint(x: -50, y: 0)))
    }

    @Test func zoomTwoDoublesTheScaleAndMovesTheCentreIntoView() {
        let placement = AvatarCropLayout.placement(crop: AvatarCrop(zoom: 2), imageSize: image, frame: 300)
        #expect(placement == AvatarCropLayout.Placement(scale: 2, offset: CGPoint(x: -250, y: -150)))
    }

    @Test func dragRightMovesTheCentreLeft() {
        let delta = AvatarCropLayout.centerDelta(
            translation: CGSize(width: 10, height: 0), crop: AvatarCrop(), imageSize: image, frame: 300)
        #expect(abs(delta.x - (-10.0 / 400)) < 1e-9)
        #expect(delta.y == 0)
    }

    @Test func zoomedDragMovesLessPerPoint() {
        let delta = AvatarCropLayout.centerDelta(
            translation: CGSize(width: 10, height: 0), crop: AvatarCrop(zoom: 2), imageSize: image, frame: 300)
        // At zoom 2 one point of drag is half a pixel of the image: 10 points = 5 pixels of 400.
        #expect(abs(delta.x - (-5.0 / 400)) < 1e-9)
    }

    @Test func emptyImageHasNoPlacement() {
        #expect(AvatarCropLayout.placement(crop: AvatarCrop(), imageSize: .zero, frame: 300) == nil)
        #expect(AvatarCropLayout.centerDelta(
            translation: CGSize(width: 5, height: 5), crop: AvatarCrop(), imageSize: .zero, frame: 300) == .zero)
    }
}
