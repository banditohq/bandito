import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → General: interface language, sample data, and launch at login.
struct GeneralSection: View {
    @Environment(DemoStore.self) private var demo
    @State private var language = Self.storedLanguage()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @AppStorage(ChatLinkSettings.openTargetDefaultsKey) private var linkTarget = ChatLinkOpenTarget.builtIn.rawValue
    @AppStorage(ChatLinkSettings.signInDefaultsKey) private var signInInMacBrowser = true
    @AppStorage(PhoneAccessRules.betaStorageKey) private var iphoneBeta = false

    private static let systemLanguage = InterfaceLanguageChoice.systemTag

    var body: some View {
        @Bindable var demo = demo
        SettingsPage(title: SettingsSection.general.title, intro: nil) {
            // The first group has no label: the page title already says "General".
            SettingsGroup(title: nil) {
                SettingsRow(
                    title: L10n.Settings.language, hint: L10n.Settings.languageRestart,
                    icon: SettingsIcon(symbol: "globe", tint: BanditoPalette.badgeBlue)
                ) {
                    BanditoSelect(
                        selection: $language, sections: [SelectSection(options: languageChoices)],
                        label: L10n.Settings.language, placeholder: L10n.Settings.Language.system,
                        field: { SelectFieldView(option: $0?.titleOnly, placeholder: L10n.Settings.Language.system) },
                        footer: { _ in EmptyView() })
                        .frame(width: 220)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.showExamples, hint: L10n.Settings.showExamplesHint,
                    icon: SettingsIcon(symbol: "sparkles", tint: BanditoPalette.badgeOrange),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $demo.enabled)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.ChatLinks.open, hint: L10n.Settings.ChatLinks.openHint,
                    icon: SettingsIcon(symbol: "link", tint: BanditoPalette.badgeTeal)
                ) {
                    BanditoSelect(
                        selection: $linkTarget,
                        sections: [
                            SelectSection(options: [
                                SelectOption(
                                    value: ChatLinkOpenTarget.builtIn.rawValue,
                                    title: L10n.Settings.ChatLinks.builtIn),
                                SelectOption(
                                    value: ChatLinkOpenTarget.macBrowser.rawValue,
                                    title: L10n.Settings.ChatLinks.macBrowser),
                            ])
                        ],
                        label: L10n.Settings.ChatLinks.open, placeholder: L10n.Settings.ChatLinks.builtIn,
                        field: { SelectFieldView(option: $0?.titleOnly, placeholder: L10n.Settings.ChatLinks.builtIn) },
                        footer: { _ in EmptyView() })
                        .frame(width: 220)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.ChatLinks.signIn, hint: L10n.Settings.ChatLinks.signInHint,
                    icon: SettingsIcon(symbol: "person.badge.key", tint: BanditoPalette.badgeIndigo),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $signInInMacBrowser)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.launchAtLogin, hint: launchError ?? L10n.Settings.launchAtLoginHint,
                    icon: SettingsIcon(symbol: "power", tint: BanditoPalette.badgeGreen),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.IphoneBeta.title, hint: L10n.Settings.IphoneBeta.hint,
                    icon: SettingsIcon(symbol: "iphone", tint: BanditoPalette.badgeSlate),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $iphoneBeta)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
            }
        }
        .onChange(of: language) { _, code in
            Self.storeLanguage(code)
        }
        .onChange(of: launchAtLogin) { _, on in
            setLaunchAtLogin(on)
        }
    }

    /// "System", then every language: its own name, and its name in the language the interface is in now.
    private var languageChoices: [SelectOption<String>] {
        SelectChoices.languages(
            system: SelectOption(value: Self.systemLanguage, title: L10n.Settings.Language.system),
            entries: L10n.languages,
            localizedName: { L10n.locale.localizedString(forIdentifier: $0) })
    }

    /// The language code the app was told to use, or "system". Reads only the app's own domain: the global
    /// `AppleLanguages` always exists and holds the system's list ("ru-RU", …), which matches no picker row.
    static func storedLanguage() -> String {
        InterfaceLanguageStore.read(from: .standard, domain: Bundle.main.bundleIdentifier ?? "")
    }

    /// Writes the choice where the system reads it at launch, so it applies after a restart.
    static func storeLanguage(_ code: String) {
        InterfaceLanguageStore.write(code, to: .standard)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            launchError = nil
        } catch {
            // The toggle's hint is a single line, so only the sentence goes here, not the technical text.
            launchError = L10n.Settings.launchFailed(error: UserFacingError.message(for: error).text)
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
