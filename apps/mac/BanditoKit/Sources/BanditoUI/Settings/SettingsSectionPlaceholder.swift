import BanditoL10n
import SwiftUI

/// Stand-in for a settings section whose controls are not built yet.
struct SettingsSectionPlaceholder: View {
    var section: SettingsSection

    var body: some View {
        SettingsPage(title: section.title, intro: L10n.Settings.placeholder) {
            EmptyView()
        }
    }
}
