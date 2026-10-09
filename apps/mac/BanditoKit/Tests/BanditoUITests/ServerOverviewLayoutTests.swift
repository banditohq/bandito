import SwiftUI
import Testing

@testable import BanditoUI

@Suite struct ServerOverviewLayoutTests {
    @Test func aPageOfExactlyTheThresholdIsWide() {
        #expect(ServerOverview.isTwoColumns(width: 1000))
    }

    @Test func aPageJustNarrowerThanTheThresholdStacksItsCards() {
        #expect(!ServerOverview.isTwoColumns(width: 999.5))
    }

    @Test func aWidePageIsTwoColumns() {
        #expect(ServerOverview.isTwoColumns(width: 1440))
    }

    @Test func anUnmeasuredPageIsNarrow() {
        #expect(!ServerOverview.isTwoColumns(width: 0))
    }
}
