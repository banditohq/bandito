import BanditoDesign
import BanditoL10n
import SwiftUI

/// The add-server sheet: the first-server step of onboarding, without its steps. A connected server is
/// selected by `AppModel.add`, and the sheet closes.
struct AddServerSheet: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer(minLength: 0)
                Button(L10n.Common.close) { close() }
                    .banditoButton(.quiet())
                    .keyboardShortcut(.cancelAction)
            }
            FirstServerStep(
                onFinished: { close() },
                onConnected: { close() })
        }
        .padding(28)
        .frame(minWidth: 680, minHeight: 460, alignment: .topLeading)
        .background(Color.Bandito.surface2)
    }

    private func close() {
        router.sheet = nil
    }
}
