import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// "Ready teams": a row of cards on the team's home and on the empty team. A card opens the team's preview
/// (`ReadyTeamSheet`); nothing is made from here. Shown only when the server has the bundles and their options.
struct ReadyTeamsSection: View {
    let bundles: [AgentBundle]
    let templates: [BotTemplate]
    let languageCode: String
    @Environment(Router.self) private var router

    private static let columns = [GridItem(.adaptive(minimum: 210, maximum: 400), spacing: 12, alignment: .top)]

    var body: some View {
        let _ = PerfCounters.hit("ReadyTeamsSection")
        let teams = ReadyTeamsLogic.teams(from: bundles)
        if !teams.isEmpty {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                ForEach(teams) { team in
                    ReadyTeamCard(
                        bundle: team, members: BundleLogic.members(of: team, templates: templates),
                        languageCode: languageCode
                    ) {
                        router.sheet = .readyTeam(bundleID: team.id)
                    }
                    .equatable()
                }
            }
        }
    }
}

/// One ready team: its tile, name, description and the small tiles of its agents. `Equatable` on what it draws.
struct ReadyTeamCard: View, Equatable {
    let bundle: AgentBundle
    let members: [BotTemplate]
    let languageCode: String
    var onOpen: () -> Void

    nonisolated static func == (lhs: ReadyTeamCard, rhs: ReadyTeamCard) -> Bool {
        lhs.bundle == rhs.bundle && lhs.members == rhs.members && lhs.languageCode == rhs.languageCode
    }

    var body: some View {
        let _ = PerfCounters.hit("ReadyTeamCard")
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    BundleTile(bundle: bundle, size: 36)
                    Text(bundle.name(languageCode: languageCode))
                        .font(BanditoFont.display(size: 12.5, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Text(bundle.description(languageCode: languageCode))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(members) { member in
                        MemberMiniTile(template: member, languageCode: languageCode, size: 22)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.Bandito.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 14))
    }
}
