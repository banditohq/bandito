import BanditoDesign
import BanditoKit
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
}
