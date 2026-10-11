import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The first screen of an agent that has no message yet: its avatar, name and role, a line that asks where to start,
/// and up to four suggestions (see `ThreadEmptyRules`). A suggestion's text goes into the composer, unsent (`onPick`).
/// It fades in and lifts a few points; under Reduce Motion only the fade remains.
struct ThreadEmptyState: View {
    let agent: Agent
    /// The server the agent lives on; the avatar needs it to load a picture.
    let server: ServerModel?
    /// Puts the text of a suggestion into the composer (see `ThreadView.pickSuggestion`).
    var onPick: (String) -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            avatar
                .padding(.bottom, 16)

            Text(agent.name)
                .font(BanditoFont.display(size: 22, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)

            if !agent.role.isEmpty {
                Text(agent.role)
                    .font(BanditoFont.text(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 4)
            }

            Text(L10n.Thread.Empty.start)
                .font(BanditoFont.text(size: 15, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .padding(.top, 28)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                ForEach(ThreadEmptyRules.suggestions(for: agent)) { suggestion in
                    chip(suggestion)
                }
            }
            .frame(maxWidth: 620)
            .padding(.top, 14)
            .padding(.horizontal, 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The lift follows Reduce Motion (`banditoAnimation` drops it); the fade is kept, so the screen never snaps in.
        .offset(y: appeared ? 0 : 10)
        .banditoAnimation(.spring(response: 0.5, dampingFraction: 0.85), value: appeared)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: appeared)
        .onAppear { appeared = true }
    }

    /// The agent's avatar at 72 pt on a soft signal glow, as the empty states draw their mascot.
    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.Bandito.signal.opacity(0.22), Color.Bandito.signal.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 90))
                .frame(width: 180, height: 180)
            AgentAvatarView(agent: agent, server: server, size: 72)
        }
        .frame(height: 120)
        .accessibilityHidden(true)
    }

    private func chip(_ suggestion: ThreadEmptyRules.Suggestion) -> some View {
        Button {
            onPick(suggestion.text)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: suggestion.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.Bandito.signal)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(suggestion.text)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 14, hoverOpacity: 0.05))
    }
}
