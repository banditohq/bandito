import Testing

@testable import BanditoUI

@Suite struct TerminalLayoutTests {
    @Test func capacitiesGrowWithTheLayout() {
        #expect(TerminalLayout.one.capacity == 1)
        #expect(TerminalLayout.cols.capacity == 2)
        #expect(TerminalLayout.mainRight.capacity == 3)
        #expect(TerminalLayout.grid.capacity == 4)
        for layout in TerminalLayout.allCases {
            #expect(layout.cells.count == layout.capacity)
        }
    }

    @Test func nextFittingPicksTheSmallestLayout() {
        #expect(TerminalLayout.next(fitting: 1) == .one)
        #expect(TerminalLayout.next(fitting: 2) == .cols)
        #expect(TerminalLayout.next(fitting: 3) == .mainRight)
        #expect(TerminalLayout.next(fitting: 4) == .grid)
        #expect(TerminalLayout.next(fitting: 5) == nil)
    }

    @Test func gridNavigationFollowsTheCells() {
        // Cells: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
        #expect(TerminalLayout.grid.neighbor(of: 0, .right) == 1)
        #expect(TerminalLayout.grid.neighbor(of: 0, .down) == 2)
        #expect(TerminalLayout.grid.neighbor(of: 3, .left) == 2)
        #expect(TerminalLayout.grid.neighbor(of: 3, .up) == 1)
        #expect(TerminalLayout.grid.neighbor(of: 0, .left) == nil)
        #expect(TerminalLayout.grid.neighbor(of: 0, .up) == nil)
    }

    @Test func mainAndTwoOnTheRightNavigation() {
        // Cells: 0 main (left, full height), 1 top-right, 2 bottom-right.
        #expect(TerminalLayout.mainRight.neighbor(of: 0, .right) == 1)
        #expect(TerminalLayout.mainRight.neighbor(of: 1, .down) == 2)
        #expect(TerminalLayout.mainRight.neighbor(of: 2, .left) == 0)
        #expect(TerminalLayout.mainRight.neighbor(of: 1, .left) == 0)
    }

    @Test func sideBySideNavigation() {
        #expect(TerminalLayout.cols.neighbor(of: 0, .right) == 1)
        #expect(TerminalLayout.cols.neighbor(of: 1, .right) == nil)
        #expect(TerminalLayout.cols.neighbor(of: 1, .up) == nil)
    }
}
