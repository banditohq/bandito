import BanditoDesign
import BanditoL10n
import SwiftUI

/// The language control of the top bar (Welcome only): a capsule with the language the interface runs in, a select
/// with the nine languages, and after a pick a hint with a restart button. The choice applies at launch, as in
/// Settings → General → Language.
struct OnboardingLanguageMenu: View {
    @State private var picked = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            BanditoSelect(
                selection: Binding(get: { Self.currentCode }, set: { code in
                    GeneralSection.storeLanguage(code)
                    picked = true
                }),
                sections: [SelectSection(options: languageChoices)],
                label: L10n.Settings.language, placeholder: InterfaceLanguage.current,
                field: { _ in
                    HStack(spacing: 7) {
                        Image(systemName: "globe")
                            .font(.system(size: 12, weight: .medium))
                            .accessibilityHidden(true)
                        Text(InterfaceLanguage.current)
                            .font(BanditoFont.font(size: 12.5, weight: 500))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .opacity(0.7)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.Bandito.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.Bandito.text.opacity(0.05), in: Capsule())
                    .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
                },
                footer: { _ in EmptyView() },
                style: .compact)
            if picked {
                HStack(spacing: 10) {
                    Text(L10n.Settings.languageRestart)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                    Button(L10n.Terminals.restart) {
                        SystemActions.relaunch()
                    }
                    .banditoButton(.quiet(size: .regular))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.text.opacity(0.1)))
            }
        }
    }

    /// The language the interface runs in now (the bundle's localization, not the stored choice).
    private static var currentCode: String {
        L10n.bundle.preferredLocalizations.first ?? "en"
    }

    /// Each language by its own name, with its code under it.
    private var languageChoices: [SelectOption<String>] {
        L10n.languages.map { entry in
            SelectOption(value: entry.code, title: entry.native, subtitle: entry.code.uppercased())
        }
    }
}
