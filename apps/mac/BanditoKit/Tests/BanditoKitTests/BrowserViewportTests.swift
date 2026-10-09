import Foundation
import Testing

@testable import BanditoKit

@Suite struct BrowserViewportTests {
    @Test func sizeIsCutToWholeCSSPixels() {
        #expect(
            BrowserViewport.fitting(width: 1000.7, height: 800.2, scale: 2)
                == BrowserViewport(width: 1000, height: 800, scale: 2))
    }

    @Test func noUsableSizeMeansNoViewport() {
        #expect(BrowserViewport.fitting(width: 0, height: 800, scale: 2) == nil)
        #expect(BrowserViewport.fitting(width: 1000, height: 0.5, scale: 2) == nil)
        #expect(BrowserViewport.fitting(width: .nan, height: 800, scale: 2) == nil)
        #expect(BrowserViewport.fitting(width: 1000, height: .infinity, scale: 2) == nil)
    }

    @Test func badScaleFallsBackToOne() {
        #expect(BrowserViewport.fitting(width: 500, height: 400, scale: 0)?.scale == 1)
        #expect(BrowserViewport.fitting(width: 500, height: 400, scale: -2)?.scale == 1)
        #expect(BrowserViewport.fitting(width: 500, height: 400, scale: .nan)?.scale == 1)
    }

    @Test func hugeAreaAndScaleAreCapped() {
        #expect(BrowserViewport.fitting(width: 1e12, height: 400, scale: 2)?.width == 10_000)
        #expect(BrowserViewport.fitting(width: 500, height: 400, scale: 9)?.scale == 4)
    }

    @Test func setViewportSetsMetricsAndNoMobileEmulation() {
        let viewport = BrowserViewport(width: 1000, height: 700, scale: 2)
        let command = CDPCommand.setViewport(viewport)
        #expect(command.method == "Emulation.setDeviceMetricsOverride")
        #expect(
            command.params
                == .object([
                    "width": .number(1000),
                    "height": .number(700),
                    "deviceScaleFactor": .number(2),
                    "mobile": .bool(false),
                ]))
    }

    @Test func clearViewportRemovesTheOverride() {
        #expect(CDPCommand.clearViewport.method == "Emulation.clearDeviceMetricsOverride")
        #expect(CDPCommand.clearViewport.params == .object([:]))
    }
}

@Suite struct BrowserScreencastBoxTests {
    @Test func boxIsThePageInDevicePixels() {
        let box = BrowserViewport(width: 1000, height: 700, scale: 2).screencastBox
        #expect(box.width == 2000)
        #expect(box.height == 1400)
    }

    @Test func boxIsCappedAtTwoThousandFiveHundredSixtyBySixteenHundred() {
        let box = BrowserViewport(width: 1900, height: 1200, scale: 2).screencastBox
        #expect(box.width == 2560)
        #expect(box.height == 1600)
    }

    @Test func fallbackBoxIsTheOldFixedSize() {
        #expect(BrowserViewport.defaultScreencast.width == 1280)
        #expect(BrowserViewport.defaultScreencast.height == 800)
    }
}
