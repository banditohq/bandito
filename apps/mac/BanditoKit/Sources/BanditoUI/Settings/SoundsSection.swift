import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Sounds: the main switch, the sound set with a listen button, the volume, which events make a sound, and
/// whether agent sounds play when the window is in the background. Off by default.
struct SoundsSection: View {
    @AppStorage(SoundSettings.enabledKey) private var enabled = false
    @AppStorage(SoundSettings.kitKey) private var kit = SoundKit.soft.rawValue
    @AppStorage(SoundSettings.volumeKey) private var volume = 0.6
    @AppStorage(SoundSettings.backgroundKey) private var playsInBackground = false

    var body: some View {
        SettingsPage(title: SettingsSection.sounds.title, intro: L10n.Settings.Sounds.intro) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: L10n.Settings.Sounds.enabled, hint: L10n.Settings.Sounds.enabledHint,
                        keepsControlBeside: true
                    ) {
                        Toggle("", isOn: $enabled)
                            .labelsHidden()
                            .toggleStyle(BanditoToggleStyle())
                    }
                    Divider().padding(.horizontal, 16)
                    SettingsRow(title: L10n.Settings.Sounds.set) {
                        HStack(spacing: 8) {
                            BanditoSelect(
                                selection: $kit, sections: [SelectSection(options: kitChoices)],
                                label: L10n.Settings.Sounds.set, placeholder: L10n.Settings.Sounds.Sets.soft,
                                field: { SelectFieldView(option: $0?.titleOnly, placeholder: L10n.Settings.Sounds.Sets.soft) },
                                footer: { _ in EmptyView() })
                                .frame(width: 220)
                            Button {
                                SoundPlayer.preview(SoundKit(rawValue: kit) ?? .soft, volume: volume)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .banditoButton(.icon(label: L10n.Settings.Sounds.listen))
                            .help(L10n.Settings.Sounds.listen)
                        }
                    }
                    Divider().padding(.horizontal, 16)
                    SettingsRow(title: L10n.Settings.Sounds.volume) {
                        Slider(value: $volume, in: 0...1)
                            .tint(Color.Bandito.signal)
                            .frame(width: 220)
                    }
                }
                .banditoCard()

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(L10n.Settings.Sounds.events)
                    VStack(spacing: 0) {
                        SoundEventRow(event: .click, title: L10n.Settings.Sounds.Event.click)
                        Divider().padding(.horizontal, 16)
                        SoundEventRow(event: .type, title: L10n.Settings.Sounds.Event.type)
                        Divider().padding(.horizontal, 16)
                        SoundEventRow(event: .tab, title: L10n.Settings.Sounds.Event.tab)
                        Divider().padding(.horizontal, 16)
                        SoundEventRow(event: .send, title: L10n.Settings.Sounds.Event.send)
                        Divider().padding(.horizontal, 16)
                        SoundEventRow(event: .done, title: L10n.Settings.Sounds.Event.done)
                        Divider().padding(.horizontal, 16)
                        SoundEventRow(event: .needsYou, title: L10n.Settings.Sounds.Event.needsYou)
                        Divider().padding(.horizontal, 16)
                        SoundEventRow(event: .error, title: L10n.Settings.Sounds.Event.error)
                    }
                    .banditoCard()
                }

                VStack(spacing: 0) {
                    SettingsRow(
                        title: L10n.Settings.Sounds.background, hint: L10n.Settings.Sounds.backgroundHint,
                        keepsControlBeside: true
                    ) {
                        Toggle("", isOn: $playsInBackground)
                            .labelsHidden()
                            .toggleStyle(BanditoToggleStyle())
                    }
                }
                .banditoCard()
            }
        }
    }

    private var kitChoices: [SelectOption<String>] {
        [
            SelectOption(value: SoundKit.soft.rawValue, title: L10n.Settings.Sounds.Sets.soft),
            SelectOption(value: SoundKit.mechanics.rawValue, title: L10n.Settings.Sounds.Sets.mechanics),
            SelectOption(value: SoundKit.glass.rawValue, title: L10n.Settings.Sounds.Sets.glass),
            SelectOption(value: SoundKit.retro.rawValue, title: L10n.Settings.Sounds.Sets.retro),
        ]
    }
}

/// One event's switch. The stored value is read and written under the event's own key.
private struct SoundEventRow: View {
    let title: String
    @AppStorage private var isOn: Bool

    init(event: SoundEvent, title: String) {
        self.title = title
        _isOn = AppStorage(wrappedValue: true, SoundSettings.eventKey(event))
    }

    var body: some View {
        SettingsRow(title: title, keepsControlBeside: true) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(BanditoToggleStyle())
        }
    }
}
