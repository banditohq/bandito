@testable import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@MainActor
@Suite struct DaemonUpdateBannerTests {
    static let offer = DaemonUpdate(current: "0.2.0", latest: "0.3.0", available: true, checkedAt: 1)

    @Test func bannerShowsWhenTheDaemonOffersAnUpdate() {
        let model = DaemonUpdateModel()
        let id = UUID()
        #expect(model.shownOffer(current: Self.offer, serverID: id) == Self.offer)
    }

    @Test func bannerIsHiddenWithoutAnOfferAndWithoutAnUpdateInProgress() {
        let model = DaemonUpdateModel()
        #expect(model.shownOffer(current: nil, serverID: UUID()) == nil)
        #expect(!model.isBusy)
    }

    @Test func statusTextIsNilWhenIdleAndNamesTheVersionOtherwise() {
        #expect(DaemonUpdateModel.statusText(for: .idle) == nil)
        #expect(DaemonUpdateModel.statusText(for: .done(version: "0.3.0"))?.contains("0.3.0") == true)
        #expect(DaemonUpdateModel.statusText(for: .timedOut(version: "0.3.0"))?.contains("0.3.0") == true)
        #expect(DaemonUpdateModel.statusText(for: .updating) != nil)
        #expect(DaemonUpdateModel.statusText(for: .failed("boom"))?.contains("boom") == true)
    }
}
