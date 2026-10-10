import CoreGraphics
import Testing

@testable import BanditoUI

@Suite struct ImageViewerZoomTests {
    private let window = CGSize(width: 900, height: 600)

    @Test func fitNeverEnlargesASmallPicture() {
        #expect(ImageViewerZoom.fitScale(image: CGSize(width: 16, height: 16), container: window) == 1)
        #expect(ImageViewerZoom.fitScale(image: CGSize(width: 450, height: 300), container: window) == 1)
    }

    @Test func fitShrinksALargePictureToTheWindow() {
        #expect(ImageViewerZoom.fitScale(image: CGSize(width: 1200, height: 600), container: window) == 0.75)
        #expect(ImageViewerZoom.fitScale(image: CGSize(width: 1200, height: 2400), container: window) == 0.25)
    }

    @Test func aVeryTallPictureFitsByHeight() {
        let fit = ImageViewerZoom.fitScale(image: CGSize(width: 600, height: 6000), container: window)
        #expect(fit == 0.1)
        // Its height fills the window, so the picture is no taller than the window.
        #expect(6000 * fit == window.height)
    }

    @Test func emptySizesGiveFullScale() {
        #expect(ImageViewerZoom.fitScale(image: .zero, container: window) == 1)
        #expect(ImageViewerZoom.fitScale(image: CGSize(width: 10, height: 10), container: .zero) == 1)
    }

    @Test func manualScaleStaysBetweenQuarterAndEight() {
        #expect(ImageViewerZoom.clamp(0.01, fit: 1) == 0.25)
        #expect(ImageViewerZoom.clamp(100, fit: 1) == 8)
        #expect(ImageViewerZoom.clamp(2, fit: 1) == 2)
    }

    @Test func aFitBelowQuarterCanBeZoomedOutToItself() {
        #expect(ImageViewerZoom.clamp(0.1, fit: 0.1) == 0.1)
        #expect(ImageViewerZoom.clamp(0.01, fit: 0.1) == 0.1)
    }

    @Test func percentRoundsToWholeNumbers() {
        #expect(ImageViewerZoom.percent(0.75) == 75)
        #expect(ImageViewerZoom.percent(1) == 100)
        #expect(ImageViewerZoom.percent(0.125) == 13)
    }

    @Test func zoomInAndOutByStepsFromFit() {
        var zoom = ImageViewerZoom()
        zoom.zoom(by: ImageViewerZoom.stepFactor, fit: 0.75)
        #expect(zoom.mode == .manual)
        #expect(zoom.effectiveScale(fit: 0.75) == 0.9375)
        zoom.zoom(by: 1 / ImageViewerZoom.stepFactor, fit: 0.75)
        #expect(abs(zoom.effectiveScale(fit: 0.75) - 0.75) < 0.0001)
    }

    @Test func repeatedZoomStopsAtTheLimits() {
        var zoom = ImageViewerZoom()
        for _ in 0..<40 { zoom.zoom(by: ImageViewerZoom.stepFactor, fit: 1) }
        #expect(zoom.effectiveScale(fit: 1) == 8)
        for _ in 0..<60 { zoom.zoom(by: 1 / ImageViewerZoom.stepFactor, fit: 1) }
        #expect(zoom.effectiveScale(fit: 1) == 0.25)
    }

    @Test func zoomKeepsThePointUnderTheAnchorInPlace() {
        var zoom = ImageViewerZoom()
        let anchor = CGPoint(x: 100, y: 50)
        // The picture point under the cursor before the zoom: (anchor - offset) / scale.
        let before = CGPoint(x: (anchor.x - zoom.offset.width) / 1, y: (anchor.y - zoom.offset.height) / 1)
        zoom.set(scale: 2, fit: 1, anchor: anchor)
        let after = CGPoint(
            x: (anchor.x - zoom.offset.width) / zoom.effectiveScale(fit: 1),
            y: (anchor.y - zoom.offset.height) / zoom.effectiveScale(fit: 1))
        #expect(abs(before.x - after.x) < 0.0001)
        #expect(abs(before.y - after.y) < 0.0001)
    }

    @Test func doubleClickGoesFromFitToActualSizeAndBack() {
        var zoom = ImageViewerZoom()
        zoom.toggle(at: CGPoint(x: 40, y: 0), fit: 0.5)
        #expect(zoom.mode == .manual)
        #expect(zoom.effectiveScale(fit: 0.5) == 1)
        zoom.toggle(at: CGPoint(x: 0, y: 0), fit: 0.5)
        #expect(zoom.mode == .fit)
        #expect(zoom.offset == .zero)
        #expect(zoom.effectiveScale(fit: 0.5) == 0.5)
    }

    @Test func aSmallPictureDoubleClickStillToggles() {
        // A 16 pt picture fits at 100%: the toggle goes to manual 100% and back to fit.
        var zoom = ImageViewerZoom()
        zoom.toggle(at: .zero, fit: 1)
        #expect(zoom.mode == .manual)
        zoom.toggle(at: .zero, fit: 1)
        #expect(zoom.mode == .fit)
    }

    @Test func panMovesOnlyWhenZoomed() {
        var zoom = ImageViewerZoom()
        zoom.pan(to: CGSize(width: 30, height: 10))
        #expect(zoom.offset == .zero)
        zoom.set(scale: 2, fit: 1)
        zoom.pan(to: CGSize(width: 30, height: 10))
        #expect(zoom.offset == CGSize(width: 30, height: 10))
    }

    @Test func panNeedsAPictureBiggerThanTheWindow() {
        let image = CGSize(width: 1200, height: 600)
        #expect(!ImageViewerZoom.canPan(image: image, scale: 0.75, container: window))
        #expect(ImageViewerZoom.canPan(image: image, scale: 1, container: window))
    }

    @Test func scrollFactorIsSmoothAndCapped() {
        #expect(ImageViewerZoom.scrollFactor(deltaY: 0) == 1)
        #expect(ImageViewerZoom.scrollFactor(deltaY: 10) > 1)
        #expect(ImageViewerZoom.scrollFactor(deltaY: -10) < 1)
        #expect(ImageViewerZoom.scrollFactor(deltaY: 10_000) == ImageViewerZoom.scrollFactor(deltaY: 50))
    }
}
