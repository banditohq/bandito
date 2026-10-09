import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Terminal and files. The values are read by the terminal and file screens.
struct TerminalFilesSection: View {
    /// Text size of new terminals, in points.
    @AppStorage("terminal.fontSize") private var fontSize = 13.0
    /// Whether the file browser shows hidden files when a folder opens.
    @AppStorage("files.showHiddenByDefault") private var showHidden = false

    var body: some View {
        SettingsPage(title: SettingsSection.terminalFiles.title, intro: L10n.Settings.TerminalFiles.intro) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.TerminalFiles.fontSize, hint: L10n.Settings.TerminalFiles.fontSizeHint) {
                    Stepper(value: $fontSize, in: 10...22, step: 1) {
                        Text("\(Int(fontSize)) pt")
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
