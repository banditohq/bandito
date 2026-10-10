import Foundation
import Testing

@testable import BanditoKit

@Suite struct BrowserPageAreasTests {
    let panel = UUID()
    let mode = UUID()
    let panelArea = BrowserPageAreas.Area(width: 420, height: 600, scale: 2)
    let modeArea = BrowserPageAreas.Area(width: 1400, height: 900, scale: 2)

    @Test func nothingOnScreenMeansNoViewport() {
        let areas = BrowserPageAreas()
        #expect(areas.isEmpty)
        #expect(areas.active == nil)
    }

    @Test func oneAreaSetsItsOwnSize() {
        var areas = BrowserPageAreas()
        areas.report(panelArea, for: panel)
        #expect(areas.active == BrowserViewport(width: 420, height: 600, scale: 2))
    }

    @Test func theAreaThatChangedLastIsActive() {
        var areas = BrowserPageAreas()
        areas.report(panelArea, for: panel)
        areas.report(modeArea, for: mode)
        #expect(areas.active == BrowserViewport(width: 1400, height: 900, scale: 2))

        // The panel changing again makes it the active one.
        areas.report(panelArea, for: panel)
        #expect(areas.active == BrowserViewport(width: 420, height: 600, scale: 2))
    }

    @Test func leavingTheScreenHandsThePageToTheAreaStillShown() {
        // Browser mode was shown after the panel; the panel is still there when the mode goes. The page must take the
        // panel's size back, not keep the mode's size (that is what made the panel draw a tiny page).
        var areas = BrowserPageAreas()
        areas.report(panelArea, for: panel)
        areas.report(modeArea, for: mode)
        areas.remove(mode)
        #expect(!areas.isEmpty)
        #expect(areas.active == BrowserViewport(width: 420, height: 600, scale: 2))
    }

    @Test func lastAreaGoneMeansNoViewport() {
        var areas = BrowserPageAreas()
        areas.report(panelArea, for: panel)
        areas.remove(panel)
        #expect(areas.isEmpty)
        #expect(areas.active == nil)
    }

    @Test func unusableAreaFallsBackToTheLastUsableOne() {
        // A collapsed panel reports no width: the page keeps the size of the area that still has one.
        var areas = BrowserPageAreas()
        areas.report(modeArea, for: mode)
        areas.report(BrowserPageAreas.Area(width: 0, height: 600, scale: 2), for: panel)
        #expect(areas.active == BrowserViewport(width: 1400, height: 900, scale: 2))
    }

    @Test func removingAnUnknownAreaChangesNothing() {
        var areas = BrowserPageAreas()
        areas.report(panelArea, for: panel)
        areas.remove(UUID())
        #expect(areas.active == BrowserViewport(width: 420, height: 600, scale: 2))
    }
}
