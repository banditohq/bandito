import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Browser and screen. Quality and clipboard are read by the browser and screen views.
struct BrowserScreenSection: View {
    @AppStorage("screen.quality") private var qualityRaw = ScreenQuality.auto.rawValue
    /// Whether the clipboard is shared between this Mac and the server's browser and screen.
    @AppStorage("screen.sharedClipboard") private var sharedClipboard = true

    private var quality: Binding<ScreenQuality> {
        Binding(get: { ScreenQuality(rawValue: qualityRaw) ?? .auto }, set: { qualityRaw = $0.rawValue })
    }

    var body: some View {
        SettingsPage(title: SettingsSection.browserScreen.title, intro: L10n.Settings.BrowserScreen.intro) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.BrowserScreen.quality, hint: L10n.Settings.BrowserScreen.qualityHint) {
                    SegmentedPicker(
                        selection: quality,
                        options: [
                            (ScreenQuality.auto, L10n.Settings.BrowserScreen.qualityAuto),
                            (ScreenQuality.faster, L10n.Settings.BrowserScreen.qualityFaster),
                            (ScreenQuality.sharper, L10n.Settings.BrowserScreen.qualitySharper),
                        ]
                    )
                    .frame(width: 280)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.BrowserScreen.clipboard, hint: L10n.Settings.BrowserScreen.clipboardHint) {
                    Toggle("", isOn: $sharedClipboard)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
            }
            .banditoCard()
        }
    }
}

/// How sharp the server's screen and browser pictures are, traded against speed.
enum ScreenQuality: String, CaseIterable, Hashable {
    case auto, faster, sharper
}
