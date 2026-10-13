import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import SwiftUI

/// The time a message was sent, at the far end of its row of actions (see `MessageContainer`). The row is drawn only on
/// hover, so this view is built for the one message under the pointer. It is `Equatable`: a re-render of that row does
/// not format the time again. It takes no space the row does not already have (the row is a fixed height).
struct MessageTimeStamp: View, Equatable {
    var date: Date

    var body: some View {
        let locale = L10n.locale
        let calendar = Calendar.current
        let full = MessageTimeLabel.fullText(date: date, calendar: calendar, locale: locale)
        Text(MessageTimeLabel.text(date: date, now: .now, calendar: calendar, locale: locale))
            .font(BanditoFont.mono(size: 11))
            .foregroundStyle(Color.Bandito.text3)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .help(full)
            .accessibilityLabel(full)
    }
}
