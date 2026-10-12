import BanditoDesign
import BanditoKit
@testable import BanditoL10n
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders the update banner in every phase to one PNG, so the card can be reviewed as an image.
@MainActor
@Suite struct UpdateBannerSnapshots {
    @Test func bannerInEveryPhase() throws {
        let center = AppUpdateCenter()
        let phases: [AppUpdateCenter.Phase] = [
            .available(version: "0.2.0"), .checking, .downloading(fraction: nil), .downloading(fraction: 0.45),
            .preparing, .installing, .upToDate,
            .failed("The operation couldn't be completed. (NSURLErrorDomain error -1009.)"),
        ]
        let column = VStack(spacing: 10) {
            ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                UpdateBanner(phase: phase, center: center)
            }
        }
        .padding(14)
        .frame(width: Sidebar.width)
        .background(Color.Bandito.surface1)
        let url = try SnapshotSupport.render(column, "update-banner", size: CGSize(width: Sidebar.width, height: 760))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The server's card in each state of its update: offered, running, done, failed, and a long server name.
    @Test func serverBannerInEveryState() throws {
        let offer = DaemonUpdate(current: "0.2.0", latest: "0.3.0", available: true, checkedAt: 1)
        let outcome = DaemonUpdate(current: "0.2.0", latest: "0.3.0", available: false, checkedAt: 1)
        let cards: [(name: String, offer: DaemonUpdate, live: Bool, phase: DaemonUpdateModel.Phase)] = [
            ("forge", offer, true, .idle),
            ("forge", offer, true, .updating),
            ("forge", outcome, false, .done(version: "0.3.0")),
            ("forge", offer, true, .failed(UserFacingMessage(text: "The server did not answer in time."))),
            ("Офисный сервер 5LB Хабаровск — основной", offer, true, .idle),
        ]
        let column = VStack(spacing: 10) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                ServerUpdateBanner(
                    serverName: card.name, offer: card.offer, isLive: card.live, phase: card.phase,
                    onInstall: {}, onDismiss: {})
            }
        }
        .padding(14)
        .frame(width: Sidebar.width)
        .background(Color.Bandito.surface1)
        // The sidebar's own width, in English and in the two languages with the longest words (German, Russian).
        for language in ["en", "de", "ru"] {
            let url = try L10n.withLanguageForTests(language) {
                try SnapshotSupport.render(
                    column, "server-update-banner-\(language)", size: CGSize(width: Sidebar.width, height: 760))
            }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
