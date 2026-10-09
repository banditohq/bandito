import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Workplaces: a short description, and the way to the Server mode where they are shown.
struct WorkplacesSection: View {
    @Environment(Router.self) private var router

    var body: some View {
        SettingsPage(title: SettingsSection.workplaces.title, intro: L10n.Settings.Workplaces.intro) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.Settings.Workplaces.body)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L10n.Settings.Workplaces.open) {
                        router.select(mode: .server)
                        router.serverSection = .workspaces
                    }
                    .banditoButton(.quiet())
                }
            }
            .padding(16)
            .banditoCard()
        }
    }
}
