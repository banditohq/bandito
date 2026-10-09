import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The details panel of the selected agent (⌘I): header, three tabs, and the tab's content.
struct InspectorView: View {
    var server: ServerModel
    var agent: Agent
    @Binding var tab: InspectorTab
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SegmentedPicker(
                selection: $tab,
                options: [
                    (InspectorTab.details, L10n.Inspector.details),
                    (InspectorTab.memory, L10n.Memory.title),
                    (InspectorTab.whereRuns, L10n.Inspector.whereRuns),
                ]
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .details: DetailsTab(server: server, agent: agent)
                    case .memory: MemoryTab(server: server, agent: agent)
                    case .whereRuns: WhereTab(server: server, agent: agent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.Bandito.surface1)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.Bandito.line).frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AgentAvatar(
                name: agent.name, size: 56,
                mood: AvatarMood.make(status: server.thread(for: agent.id).status, paused: agent.paused))
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(BanditoFont.font(size: 19, weight: 650))
                    .foregroundStyle(Color.Bandito.text)
                Text(subtitle)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text3)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(Color.Bandito.line, lineWidth: 1))
                    .contentShape(Circle())
            }
            .banditoButton(.row(cornerRadius: 15, hoverOpacity: 0.08))
            .help(L10n.Common.close)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var subtitle: String {
        [agent.role.isEmpty ? nil : agent.role, agent.runtime.title, agent.model].compactMap { $0 }
            .joined(separator: " · ")
    }
}

// MARK: - Shared pieces

/// A rounded group of rows, as in the design's detail cards.
struct InspectorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.Bandito.text.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }
}

/// One line of a card: the label on the left, the value (text or control) on the right.
struct InspectorRow<Value: View>: View {
    var label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            Spacer(minLength: 10)
            value
                .font(BanditoFont.font(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
    }
}

/// Error line for a failed change in a tab.
struct InspectorError: View {
    var text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.font(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.danger)
            .textSelection(.enabled)
    }
}
