import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// What the page of a connected service needs for its "Journal" section.
struct JournalSectionInput {
    var journal: CallJournal
    var loading: Bool
    var error: UserFacingMessage?
    var agents: [Agent]
    var server: ServerModel?
    var onMore: () -> Void
}

/// The body of the "Journal" section: the last calls to the service's tools, newest first, and Show more.
struct CallJournalBody: View {
    let input: JournalSectionInput

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if input.journal.rows.isEmpty {
                if let error = input.error {
                    UserFacingErrorView(message: error)
                } else if !input.loading {
                    Text(L10n.Market.Journal.empty)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(Array(input.journal.rows.enumerated()), id: \.element.id) { index, call in
                    if index > 0 {
                        Rectangle().fill(Color.Bandito.line).frame(height: 1)
                    }
                    CallJournalRow(
                        call: call, agent: input.agents.first { $0.id == call.agentId }, server: input.server)
                }
                if let error = input.error {
                    UserFacingErrorView(message: error).padding(.top, 8)
                }
                if input.journal.hasMore {
                    Button(L10n.Market.Journal.more, action: input.onMore)
                        .banditoButton(.quiet())
                        .disabled(input.loading)
                        .fixedSize()
                        .padding(.top, 10)
                }
            }
        }
    }
}

/// One call: who, which tool, when and how long, how it ended, and the policy's word in quiet type.
private struct CallJournalRow: View {
    let call: ToolCallRecord
    let agent: Agent?
    let server: ServerModel?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                Text(call.tool)
                    .font(BanditoFont.mono(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                if case .failed(let text?) = CallJournalText.outcome(call) {
                    Text(text)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                outcome
                if let decision = call.decision {
                    Text(CallJournalText.decision(decision))
                        .font(BanditoFont.text(size: 11, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var avatar: some View {
        if let agent {
            AgentAvatarView(agent: agent, server: server, size: 24)
        } else {
            AgentAvatar(name: "?", size: 24)
        }
    }

    /// The agent, the time and the duration, in one line.
    private var meta: String {
        [agent?.name, CallJournalText.time(call.atMs), CallJournalText.duration(call.durationMs)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var outcome: some View {
        switch CallJournalText.outcome(call) {
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.Bandito.ok)
                .accessibilityLabel(L10n.Market.Journal.succeeded)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.Bandito.danger)
                .accessibilityLabel(L10n.Market.Journal.failed)
        case .noResult:
            Text(L10n.Market.Journal.noResult)
                .font(BanditoFont.text(size: 11, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
        }
    }
}
