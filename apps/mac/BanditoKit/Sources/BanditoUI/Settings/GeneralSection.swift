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

    private static let languageKey = "AppleLanguages"
    private static let systemLanguage = "system"

    var body: some View {
        @Bindable var demo = demo
        SettingsPage(title: SettingsSection.general.title, intro: nil) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.language, hint: L10n.Settings.languageRestart) {
                    Picker("", selection: $language) {
                        Text(L10n.Settings.Language.system).tag(Self.systemLanguage)
                        ForEach(L10n.languages, id: \.code) { entry in
                            Text(entry.native).tag(entry.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.showExamples, hint: L10n.Settings.showExamplesHint) {
                    Toggle("", isOn: $demo.enabled)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.launchAtLogin, hint: launchError) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.autoCheckUpdates, hint: L10n.Settings.autoCheckUpdatesHint) {
                    Toggle("", isOn: $autoCheckUpdates)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.Updates.channel, hint: L10n.Settings.channelHint) {
                    Picker("", selection: $updateChannel) {
                        Text(L10n.Settings.Updates.stable).tag(AppUpdatePreferences.Channel.stable.rawValue)
                        Text(L10n.Settings.Updates.beta).tag(AppUpdatePreferences.Channel.beta.rawValue)
                    }
                    .labelsHidden()
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

    /// The language code the app was told to use, or "system".
    static func storedLanguage() -> String {
        (UserDefaults.standard.array(forKey: languageKey) as? [String])?.first ?? systemLanguage
    }

    /// Writes the choice where the system reads it at launch, so it applies after a restart.
    static func storeLanguage(_ code: String) {
        if code == systemLanguage {
            UserDefaults.standard.removeObject(forKey: languageKey)
        } else {
            UserDefaults.standard.set([code], forKey: languageKey)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            launchError = nil
        } catch {
            launchError = L10n.Settings.launchFailed(error: error.localizedDescription)
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
