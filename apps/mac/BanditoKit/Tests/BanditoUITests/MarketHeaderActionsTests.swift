import SwiftUI
import Testing

@testable import BanditoUI

/// The Marketplace header's actions render at the widths of the window range, from the narrowest to the widest, with
/// the search field in each. The pictures show which form (text, icons, menu) each width takes.
@MainActor
@Suite struct MarketHeaderActionsTests {
    private func header() -> some View {
        MarketHeaderActions(
            showsSearch: true,
            search: Capsule().fill(Color.Bandito.text.opacity(0.05)).frame(width: 240, height: 32),
            addsIntegration: true,
            showsMine: true,
            onImport: {},
            onOwn: {},
            onMine: {})
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Bandito.bg)
    }

    @Test func rendersAtMinimumAndWideWidths() throws {
        for width in [CGFloat(380), 560, 900, 1200, 1600] {
            let url = try SnapshotSupport.render(header(), "market-header-\(Int(width))", size: CGSize(width: width, height: 60))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
