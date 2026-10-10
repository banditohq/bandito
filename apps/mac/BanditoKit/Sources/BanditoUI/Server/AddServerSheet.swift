import BanditoDesign
import BanditoL10n
import SwiftUI

/// The add-server sheet: the first-server step of onboarding, without its steps. A connected server is
/// selected by `AppModel.add`, and the sheet closes.
struct AddServerSheet: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The header stays on top; the step scrolls when it is taller than the window (every step of the flow).
            HStack {
                Spacer(minLength: 0)
                Button(L10n.Common.close) { close() }
                    .banditoButton(.quiet())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 18)
            ScrollView {
                FirstServerStep(
                    onFinished: { close() },
                    onConnected: { close() })
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
        .padding(28)
        // Not taller than the window: the sheet takes the window's height at most, and the scroll view takes the rest.
        .frame(minWidth: 680, minHeight: 460, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Bandito.surface2)
    }

    private func close() {
        router.sheet = nil
    }
}
