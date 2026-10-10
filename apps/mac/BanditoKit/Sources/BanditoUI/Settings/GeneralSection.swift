import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → General: interface language, sample data, launch at login, and how the app updates itself.
struct GeneralSection: View {
    @Environment(DemoStore.self) private var demo
    @State private var language = Self.storedLanguage()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    // The app target reads these keys and configures Sparkle (AppUpdater).
    @AppStorage(AppUpdatePreferences.automaticChecksKey) private var autoCheckUpdates = true
    @AppStorage(AppUpdatePreferences.channelKey) private var updateChannel = AppUpdatePreferences.Channel.stable.rawValue

    private static let systemLanguage = InterfaceLanguageChoice.systemTag

    var body: some View {
        @Bindable var demo = demo
        SettingsPage(title: SettingsSection.general.title, intro: nil) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.language, hint: L10n.Settings.languageRestart) {
                    BanditoSelect(
                        selection: $language, sections: [SelectSection(options: languageChoices)],
                        label: L10n.Settings.language, placeholder: L10n.Settings.Language.system,
                        field: { SelectFieldView(option: $0?.titleOnly, placeholder: L10n.Settings.Language.system) },
                        footer: { _ in EmptyView() })
                        .frame(width: 220)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.showExamples, hint: L10n.Settings.showExamplesHint, keepsControlBeside: true
                ) {
                    Toggle("", isOn: $demo.enabled)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.launchAtLogin, hint: launchError ?? L10n.Settings.launchAtLoginHint,
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.autoCheckUpdates, hint: L10n.Settings.autoCheckUpdatesHint,
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $autoCheckUpdates)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.Updates.channel, hint: L10n.Settings.channelHint) {
                    BanditoSelect(
                        selection: $updateChannel,
                        sections: [
                            SelectSection(options: [
                                SelectOption(
                                    value: AppUpdatePreferences.Channel.stable.rawValue,
                                    title: L10n.Settings.Updates.stable, subtitle: L10n.Settings.Updates.stableDesc),
                                SelectOption(
                                    value: AppUpdatePreferences.Channel.beta.rawValue,
                                    title: L10n.Settings.Updates.beta, subtitle: L10n.Settings.Updates.betaDesc),
                            ])
                        ],
                        label: L10n.Settings.Updates.channel, placeholder: L10n.Settings.Updates.stable,
                        field: { SelectFieldView(option: $0?.titleOnly, placeholder: L10n.Settings.Updates.stable) },
                        footer: { _ in EmptyView() })
                        .frame(width: 220)
                }
            }
            .banditoCard()
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
