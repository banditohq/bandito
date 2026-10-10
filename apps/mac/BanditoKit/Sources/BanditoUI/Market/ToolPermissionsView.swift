import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// What the page of a connected service needs for its "Tools" section.
struct ToolsSectionInput {
    /// The tools the last check listed.
    var tools: [IntegrationTool]
    /// A change is being saved: the controls wait, so two changes cannot overwrite each other.
    var saving: Bool
    var error: UserFacingMessage?
    /// Names of agents the modes do not reach (Codex and Grok).
    var unreached: [String]
    var onMode: (IntegrationToolMode) -> Void
    var onWord: (IntegrationTool, ToolWord) -> Void
    var onCheck: () -> Void
}

/// The body of the "Tools" section: the mode as three segments, a line that says what it does, and every tool with
/// what it does (reads, changes, deletes) and the owner's word on it.
struct ToolPermissionsBody: View {
    let integration: Integration
    let input: ToolsSectionInput

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SegmentedPicker(
                selection: Binding(get: { integration.toolMode }, set: { input.onMode($0) }),
                options: [IntegrationToolMode.all, .confirmWrites, .readOnly].map { ($0, Self.title($0)) }
            )
            .fixedSize()
            .disabled(input.saving)
            Text(Self.hint(integration.toolMode))
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            list
            if !input.unreached.isEmpty {
                Text(L10n.Market.Tools.unreached(agents: input.unreached.joined(separator: ", ")))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = input.error {
                UserFacingErrorView(message: error)
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        switch ToolPermissionLogic.content(input.tools) {
        case .notChecked:
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Market.Tools.notChecked)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.Integrations.check, action: input.onCheck)
                    .banditoButton(.quiet())
                    .fixedSize()
            }
        case .tools(let tools):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tools) { tool in
                    Rectangle().fill(Color.Bandito.line).frame(height: 1)
                    ToolRow(
                        tool: tool,
                        word: ToolPermissionLogic.effectiveWord(
                            of: tool, mode: integration.toolMode, overrides: integration.toolOverrides),
                        saving: input.saving,
                        onWord: { input.onWord(tool, $0) })
                }
            }
        }
    }

    static func title(_ mode: IntegrationToolMode) -> String {
        switch mode {
        case .all: L10n.Market.Tools.Mode.all
        case .confirmWrites: L10n.Market.Tools.Mode.confirmWrites
        case .readOnly: L10n.Market.Tools.Mode.readOnly
        }
    }

    static func hint(_ mode: IntegrationToolMode) -> String {
        switch mode {
        case .all: L10n.Market.Tools.Hint.all
        case .confirmWrites: L10n.Market.Tools.Hint.confirmWrites
        case .readOnly: L10n.Market.Tools.Hint.readOnly
        }
    }

    static func title(_ word: ToolWord) -> String {
        switch word {
        case .allow: L10n.Market.Tools.Word.allow
        case .ask: L10n.Market.Tools.Word.ask
        case .deny: L10n.Market.Tools.Word.deny
        }
    }
}

/// One tool: its name, what it does, a line from its description, and the three words.
private struct ToolRow: View {
    let tool: IntegrationTool
    let word: ToolWord
    let saving: Bool
    var onWord: (ToolWord) -> Void

    var body: some View {
        let kind = ToolPermissionLogic.kind(of: tool)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(tool.name)
                        .font(BanditoFont.mono(size: 12.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Chip(text: kind.title, tone: tone(kind))
                }
                if let line = summary {
                    Text(line)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SegmentedPicker(
                selection: Binding(get: { word }, set: { onWord($0) }),
                options: ToolWord.allCases.map { ($0, ToolPermissionsBody.title($0)) }
            )
            .fixedSize()
            .disabled(saving)
        }
        .padding(.vertical, 10)
    }

    private func tone(_ kind: ToolPermissionLogic.Kind) -> ChipTone {
        switch kind {
        case .reads: .neutral
        case .changes: .warning
        case .deletes: .danger
        }
    }

    /// The title when it says more than the name, else the first line of the description.
    private var summary: String? {
        let text = tool.title ?? tool.description
        return text?.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
