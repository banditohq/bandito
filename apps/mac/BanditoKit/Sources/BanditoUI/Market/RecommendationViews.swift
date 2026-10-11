import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// A card of the "suited to the project" shelf: the service, why it was suggested, the file that showed it, and
/// Connect. It takes the width and the height its shelf gives it. `Equatable` on the suggestion, so a redraw of the
/// page does not rebuild it.
struct RecommendationCard: View, Equatable {
    let item: RecommendationLogic.Item
    var onConnect: () -> Void

    nonisolated static func == (lhs: RecommendationCard, rhs: RecommendationCard) -> Bool { lhs.item == rhs.item }

    var body: some View {
        let entry = MarketEntry(
            id: "catalog:\(item.template.id)", name: item.template.name, description: "", template: item.template,
            integration: nil)
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    MarketTile(entry: entry, size: 28)
                    Text(item.template.name)
                        .font(BanditoFont.text(size: 13.5, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(RecommendationLogic.reasonText(item.reasonKey))
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.evidence)
                    .font(BanditoFont.mono(size: 10.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(L10n.Integrations.connect, action: onConnect)
                    .banditoButton(.quiet())
                    .fixedSize()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
