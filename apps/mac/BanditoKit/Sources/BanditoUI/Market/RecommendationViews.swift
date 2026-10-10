import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// A compact card of the "suited to the project" row: the service, why it was suggested, the file that showed it,
/// and Connect.
struct RecommendationCard: View {
    let item: RecommendationLogic.Item
    var onConnect: () -> Void

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
            .frame(width: 230, alignment: .topLeading)
        }
    }
}
