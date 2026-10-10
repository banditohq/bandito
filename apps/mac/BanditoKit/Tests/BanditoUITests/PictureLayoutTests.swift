import CoreGraphics
import Testing

@testable import BanditoUI

@Suite struct PictureLayoutTests {
    @Test func aSinglePictureIsASquareUntilItsSizeIsKnown() {
        #expect(PictureLayout.frame(single: true, natural: nil) == CGSize(width: 120, height: 120))
    }

    @Test func aSinglePictureKeepsItsProportionsInTheBox() {
        #expect(PictureLayout.frame(single: true, natural: CGSize(width: 1200, height: 600)) == CGSize(width: 260, height: 130))
        #expect(PictureLayout.frame(single: true, natural: CGSize(width: 600, height: 6000)) == CGSize(width: 20, height: 200))
    }

    @Test func aSmallSinglePictureIsNotEnlarged() {
        #expect(PictureLayout.frame(single: true, natural: CGSize(width: 16, height: 16)) == CGSize(width: 16, height: 16))
    }

    @Test func severalPicturesAreAlwaysSquares() {
        #expect(PictureLayout.frame(single: false, natural: nil) == CGSize(width: 120, height: 120))
        #expect(PictureLayout.frame(single: false, natural: CGSize(width: 1200, height: 600)) == CGSize(width: 120, height: 120))
    }

    @Test func miniaturesAreAtMostFiveHundredTwentyPixels() {
        #expect(PictureLayout.miniaturePixels == 520)
    }
}
