import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The capsule at the top of the thread: avatar, name, model and effort, status; on the right, the actions
/// (changes, terminal, schedules, details).
struct ThreadHeader: View {
    var agent: Agent
    var status: AgentStatus
    var turnRunning: Bool
    /// Changes since the last checkpoint; `nil` when not loaded.
    var changes: ChangesDiff?
    /// Whether the server has the `changes` feature. Without it the changes button is hidden.
    var showsChanges: Bool
    /// Whether the server has the `terminals` feature. Without it the terminal button is hidden.
    var showsTerminal: Bool
    var onChanges: () -> Void = {}
    var onTerminal: () -> Void = {}
    var onSchedules: () -> Void = {}
    var onDetails: () -> Void = {}

    var body: some View {
        ZStack {
            capsule
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Spacer()
                if showsChanges {
                    changesButton
                }
                if showsTerminal {
                    iconButton("terminal", help: L10n.Team.Header.terminal, action: onTerminal)
                }
                iconButton("clock", help: L10n.Team.Header.schedules, action: onSchedules)
                iconButton("sidebar.right", help: L10n.Inspector.toggleAria, action: onDetails)
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
    }

    private var capsule: some View {
        HStack(spacing: 9) {
            AgentAvatar(
                name: agent.name, size: 26,
                mood: AvatarMood.make(status: status, turnRunning: turnRunning, paused: agent.paused))
            Text(agent.name)
                .font(BanditoFont.font(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            if !caption.isEmpty {
                Text(caption)
                    .font(BanditoFont.font(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            Rectangle().fill(Color.Bandito.text.opacity(0.12)).frame(width: 1, height: 14)
            Text(status.title)
                .font(BanditoFont.font(size: 12, weight: 600))
                .foregroundStyle(statusTint)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
        .background(Color.Bandito.surface1.opacity(0.8), in: Capsule())
        .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
    }

    private var caption: String {
        [agent.model ?? agent.runtime.title, agent.effort?.title].compactMap { $0 }.joined(separator: " · ")
    }

    private var statusTint: Color {
        switch status {
        case .needsYou: Color.Bandito.signal
        case .working: Color.Bandito.ok
        case .error: Color.Bandito.danger
        case .idle, .offline: Color.Bandito.text3
        }
    }

    private var changesButton: some View {
        // With no changes the button is just the word, dimmed: "+0 −0" says nothing.
        let counted = (changes?.additions ?? 0) + (changes?.deletions ?? 0) > 0
        return Button(action: onChanges) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.Team.changes)
                    .lineLimit(1)
                    .fixedSize()
                if let changes, counted {
                    HStack(spacing: 4) {
                        Text("+\(changes.additions)").foregroundStyle(Color.Bandito.ok)
                        Text("−\(changes.deletions)").foregroundStyle(Color.Bandito.danger)
                    }
                    .font(BanditoFont.font(size: 11, weight: 500, mono: true))
                }
            }
            .font(BanditoFont.font(size: 12, weight: 500))
            .foregroundStyle(counted ? Color.Bandito.text : Color.Bandito.text3)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.Bandito.text.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
        }
        .banditoButton(.row(cornerRadius: 15, hoverOpacity: 0.08))
        .help(L10n.Team.changes)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 30, height: 30)
        }
        .banditoButton(.icon(size: 30, label: help))
        .help(help)
    }
}
