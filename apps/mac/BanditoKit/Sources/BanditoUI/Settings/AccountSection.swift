import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Account and sync. Sign-in itself happens in the account sheet (shared with onboarding).
struct AccountSection: View {
    @Environment(Router.self) private var router

    var body: some View {
        SettingsPage(title: SettingsSection.account.title, intro: L10n.Settings.Account.intro) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.Account.state, hint: L10n.Settings.Account.signedOutHint) {
                    Button(L10n.Settings.Account.signIn) {
                        router.sheet = .account
                    }
                    .buttonStyle(SignalButtonStyle())
                }
            }
            .banditoCard()
        }
    }
}
