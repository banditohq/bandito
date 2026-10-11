import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders the "Tools" section of a service to PNG (no window, no app), to look at it.
@MainActor
@Suite struct ToolsSectionSnapshot {
    @Test func toolsSection() throws {
        let integration = Integration(
            id: "i", name: "linear", kind: .http, toolMode: .confirmWrites, toolOverrides: ["list_issues": .deny])
        let tools = [
            IntegrationTool(name: "list_issues", title: "List issues", readOnly: true),
            IntegrationTool(name: "save_issue", description: "Create or update an issue"),
            IntegrationTool(name: "delete_comment", description: "Delete a comment", destructive: true),
        ]
        let input = ToolsSectionInput(
            tools: tools, saving: false, error: nil, unreached: ["Reviewer"], onMode: { _ in }, onWord: { _, _ in },
            onCheck: {})
        let view = ToolPermissionsBody(integration: integration, input: input)
            .padding(20).frame(width: 720).background(Color.Bandito.surface1)
        let url = try SnapshotSupport.render(view, "market-tools", size: CGSize(width: 720, height: 420))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
