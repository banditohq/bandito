import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// The card an agent shows to ask for a service: waiting, and the three ways it ends.
@MainActor
@Suite struct ConnectCardSnapshots {
    private let github = IntegrationCatalogEntry(
        id: "github", name: "GitHub", descriptionEn: "", descriptionRu: "", kind: .http, url: "https://api.githubcopilot.com/mcp/",
        docsUrl: "", icon: "github", accent: "#24292F")
    private let linear = IntegrationCatalogEntry(
        id: "linear", name: "Linear", descriptionEn: "", descriptionRu: "", kind: .http, url: "https://mcp.linear.app/mcp",
        docsUrl: "", icon: "linear", accent: "#5E6AD2", auth: .oauth)

    @Test func theCardInItsStates() throws {
        let catalog = [github, linear]
        func card(_ row: ConnectRow) -> some View {
            ConnectCard(row: row, agentName: "Forge", onConnect: {}, onDecline: {}, catalog: catalog)
        }
        let view = VStack(alignment: .leading, spacing: 18) {
            card(ConnectRow(requestId: "1", service: "linear", reason: "To read the open issues and file the bug you described.", ts: 1))
            card(ConnectRow(requestId: "2", service: "github", reason: nil, ts: 2))
            card(ConnectRow(requestId: "3", service: "linear", outcome: .connected(integration: "linear"), ts: 3))
            card(ConnectRow(requestId: "4", service: "github", outcome: .declined, ts: 4))
            card(ConnectRow(requestId: "5", service: "mystery", outcome: .expired, ts: 5))
        }
        .padding(24)
        .background(Color(red: 0.07, green: 0.063, blue: 0.055))
        let url = try SnapshotSupport.render(view, "chat-connect-card", size: CGSize(width: 760, height: 620))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
