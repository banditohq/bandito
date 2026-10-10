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
            SettingsGroup(title: L10n.Settings.Group.playback) {
                SettingsRow(
                    title: L10n.Settings.Sounds.enabled, hint: L10n.Settings.Sounds.enabledHint,
                    icon: SettingsIcon(symbol: "speaker.wave.2.fill", tint: BanditoPalette.badgeBrown),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.Sounds.set,
                    icon: SettingsIcon(symbol: "music.note.list", tint: BanditoPalette.badgePink)
                ) {
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
                SettingsRow(
                    title: L10n.Settings.Sounds.volume,
                    icon: SettingsIcon(symbol: "speaker.wave.3.fill", tint: BanditoPalette.badgeGray)
                ) {
                    Slider(value: $volume, in: 0...1)
                        .tint(Color.Bandito.signal)
                        .frame(width: 220)
                }
            }

            SettingsGroup(title: L10n.Settings.Sounds.events) {
                SoundEventRow(
                    event: .click, title: L10n.Settings.Sounds.Event.click,
                    symbol: "cursorarrow.click", tint: BanditoPalette.badgeGray)
                Divider().padding(.horizontal, 16)
                SoundEventRow(
                    event: .type, title: L10n.Settings.Sounds.Event.type,
                    symbol: "keyboard", tint: BanditoPalette.badgeDarkGray)
                Divider().padding(.horizontal, 16)
                SoundEventRow(
                    event: .tab, title: L10n.Settings.Sounds.Event.tab,
                    symbol: "sidebar.left", tint: BanditoPalette.badgeTeal)
                Divider().padding(.horizontal, 16)
                SoundEventRow(
                    event: .send, title: L10n.Settings.Sounds.Event.send,
                    symbol: "paperplane.fill", tint: BanditoPalette.badgeBlue)
                Divider().padding(.horizontal, 16)
                SoundEventRow(
                    event: .done, title: L10n.Settings.Sounds.Event.done,
                    symbol: "checkmark.circle.fill", tint: BanditoPalette.badgeGreen)
                Divider().padding(.horizontal, 16)
                SoundEventRow(
                    event: .needsYou, title: L10n.Settings.Sounds.Event.needsYou,
                    symbol: "exclamationmark.bubble.fill", tint: BanditoPalette.badgeOrange)
                Divider().padding(.horizontal, 16)
                SoundEventRow(
                    event: .error, title: L10n.Settings.Sounds.Event.error,
                    symbol: "xmark.octagon.fill", tint: BanditoPalette.badgeRed)
            }

            SettingsGroup(title: L10n.Settings.Group.background) {
                SettingsRow(
                    title: L10n.Settings.Sounds.background, hint: L10n.Settings.Sounds.backgroundHint,
                    icon: SettingsIcon(symbol: "moon.fill", tint: BanditoPalette.badgeIndigo),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $playsInBackground)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
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
    let symbol: String
    let tint: Color
    @AppStorage private var isOn: Bool

    init(event: SoundEvent, title: String, symbol: String, tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        _isOn = AppStorage(wrappedValue: true, SoundSettings.eventKey(event))
    }

    var body: some View {
        SettingsRow(
            title: title, icon: SettingsIcon(symbol: symbol, tint: tint), keepsControlBeside: true
        ) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(BanditoToggleStyle())
        }
    }
}
