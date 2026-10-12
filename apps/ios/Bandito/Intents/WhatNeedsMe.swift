import BanditoDesign
import BanditoL10n
import SwiftUI

/// The line Siri says for "What needs me": the number that waits (the widget's number), the names of the first two
/// waiting agents and "and N more". Pure, so the Russian plurals are tested.
enum WhatNeedsMeText {
    static func line(for snapshot: WidgetSnapshot?) -> String {
        line(pending: snapshot?.pending ?? 0, waitingNames: snapshot?.waitingNames ?? [], more: snapshot?.waitingMore ?? 0)
    }

    static func line(pending: Int, waitingNames names: [String], more: Int) -> String {
        guard pending > 0 else { return L10n.Ios.Intent.NeedsMe.none }
        guard !names.isEmpty else { return L10n.Ios.Intent.NeedsMe.countOnly(count: pending) }
        var list = names.joined(separator: ", ")
        if more > 0 { list = L10n.Ios.Widget.more(names: list, count: more) }
        return L10n.Ios.Intent.NeedsMe.waiting(count: pending, names: list)
    }
}

/// The snippet under the line: the small widget as it is on the home screen, and a button to the Inbox.
struct WhatNeedsMeSnippet: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(spacing: BanditoSpace.s3) {
            InboxWidgetView(snapshot: snapshot, family: .systemSmall)
                .padding(14)
                .frame(width: 170, height: 170, alignment: .topLeading)
                .background(WidgetBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Button(intent: OpenInboxIntent()) {
                Text(L10n.Ios.Intent.Open.inbox)
            }
            .buttonStyle(SignalButtonStyle())
        }
        .padding(BanditoSpace.s2)
    }
}
