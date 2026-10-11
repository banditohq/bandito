import SwiftUI
import Testing

@testable import BanditoUI

/// The Marketplace header's actions render at the widths of the window range, from the narrowest to the widest, with
/// the search field in each. The pictures show which form (text, icons, menu) each width takes.
@MainActor
@Suite struct MarketHeaderActionsTests {
    private func header(width: CGFloat) -> some View {
        MarketHeaderActions(
            showsSearch: true,
            search: Capsule().fill(Color.Bandito.text.opacity(0.05)).frame(width: 240, height: 32),
            addsIntegration: true,
            showsMine: true,
            onImport: {},
            onOwn: {},
            onMine: {},
            available: width - 60)
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Bandito.bg)
    }

    @Test func rendersAtMinimumAndWideWidths() throws {
        for width in [CGFloat(380), 560, 900, 1200, 1600] {
            let url = try SnapshotSupport.render(header(width: width), "market-header-\(Int(width))", size: CGSize(width: width, height: 60))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func theFirstFormThatFitsIsShown() {
        let widths: [MarketHeaderFit.Form: CGFloat] = [.text: 330, .icons: 120, .menu: 32]
        let field = MarketSearchField.width + MarketHeaderFit.spacing
        #expect(MarketHeaderFit.form(available: nil, widths: widths, search: true) == .text)
        #expect(MarketHeaderFit.form(available: field + 330, widths: widths, search: true) == .text)
        #expect(MarketHeaderFit.form(available: field + 329, widths: widths, search: true) == .icons)
        #expect(MarketHeaderFit.form(available: field + 100, widths: widths, search: true) == .menu)
        #expect(MarketHeaderFit.form(available: 330, widths: widths, search: false) == .text)
        // Not measured yet: the form is tried as if it fits, so it gets measured.
        #expect(MarketHeaderFit.form(available: 50, widths: [:], search: true) == .text)
    }
}
