import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Language. The same choice as in General; it takes effect after a restart.
struct LanguageSection: View {
    @State private var language = GeneralSection.storedLanguage()

    var body: some View {
        SettingsPage(title: SettingsSection.language.title, intro: nil) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.language, hint: L10n.Settings.languageRestart) {
                    Picker("", selection: $language) {
                        Text(L10n.Settings.Language.system).tag("system")
                        ForEach(L10n.languages, id: \.code) { entry in
                            Text(entry.native).tag(entry.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            .banditoCard()
        }
        .onChange(of: language) { _, code in
            GeneralSection.storeLanguage(code)
        }
    }
}
