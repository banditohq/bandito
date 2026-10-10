import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The team has no agents yet: the raccoon, one line about agents, the button for the first one, and three
/// starting templates. A template opens the new agent sheet with its runtime, effort and instructions filled in.
struct TeamWelcome: View {
    @Environment(Router.self) private var router

    /// The starting points offered on the empty team.
    static let templates: [AgentTemplate] = [.builder, .reviewer, .oncall]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                RaccoonAvatar(name: "Bandito", color: .peach, face: .chevronDash, size: 72)
                VStack(spacing: 8) {
                    Text(L10n.Team.welcomeTitle)
                        .font(BanditoFont.display(size: 20, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(L10n.Team.welcomeBody)
                        .font(BanditoFont.text(size: 13.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L10n.New.agent) {
                    router.sheet = .newAgent
                }
                .banditoButton(.signal(size: .large))
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { templateCards }
                    VStack(spacing: 12) { templateCards }
                }
                .frame(maxWidth: 640)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
    }

    @ViewBuilder
    private var templateCards: some View {
        ForEach(Self.templates, id: \.self) { template in
            templateCard(template)
        }
    }

    private func templateCard(_ template: AgentTemplate) -> some View {
        Button {
            router.pendingTemplate = template
            router.sheet = .newAgent
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(template.title)
                    .font(BanditoFont.display(size: 12.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(template.description)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
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
