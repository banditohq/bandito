import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Terminal and files. The values are read by the terminal and file screens.
struct TerminalFilesSection: View {
    @Environment(AppModel.self) private var app
    /// Whether the file browser shows hidden files when a folder opens.
    @AppStorage(FolderModel.showHiddenDefaultsKey) private var showHidden = false

    /// The terminals' text size is the app's one `TerminalFontStore`, so ⌘+ and this stepper agree.
    private var fontSize: Binding<Double> {
        Binding(get: { app.terminalFont.size }, set: { app.terminalFont.set($0) })
    }

    var body: some View {
        SettingsPage(title: SettingsSection.terminalFiles.title, intro: L10n.Settings.TerminalFiles.intro) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.TerminalFiles.fontSize, hint: L10n.Settings.TerminalFiles.fontSizeHint) {
                    Stepper(value: fontSize, in: TerminalFontSize.range, step: TerminalFontSize.step) {
                        Text(String(format: "%g pt", app.terminalFont.size))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.Bandito.text2)
                    }
                    .fixedSize()
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.TerminalFiles.showHidden, hint: L10n.Settings.TerminalFiles.showHiddenHint) {
                    Toggle("", isOn: $showHidden)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
            }
            .banditoCard()
        }
    }
}
