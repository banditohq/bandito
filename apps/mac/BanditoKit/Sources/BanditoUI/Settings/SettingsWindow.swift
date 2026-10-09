import BanditoDesign
import BanditoL10n
import SwiftUI

/// The Settings window (⌘,): 12 sections in a left navigation, 1040 × 760 pt, like the design.
public struct SettingsWindow: View {
    @State private var section: SettingsSection = .general

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            navigation
                .frame(width: 240)
                .frame(maxHeight: .infinity)
                .background(Color.Bandito.bg)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.Bandito.surface1)
        }
        .frame(width: 1040, height: 760)
        .preferredColorScheme(.dark)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.Settings.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .padding(.horizontal, 10)
                .padding(.top, 26)
                .padding(.bottom, 14)
            ForEach(SettingsSection.allCases) { item in
                let selected = item == section
                Button {
                    section = item
                } label: {
                    HStack(spacing: 10) {
                        Text(item.glyph)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 22, height: 22)
                            .foregroundStyle(selected ? Color.white : Color.Bandito.text3)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(selected ? Color.Bandito.signal : Color.Bandito.text.opacity(0.06)))
                        Text(item.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Color.Bandito.text.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSection()
        case .account: AccountSection()
        case .servers: ServersSection()
        case .approvals: ApprovalsSection()
        case .usage: UsageSection()
        case .workplaces: WorkplacesSection()
        case .terminalFiles: TerminalFilesSection()
        case .browserScreen: BrowserScreenSection()
        case .keysGestures: KeysAndGesturesSection()
        case .notifications: NotificationsSection()
        case .appearance: AppearanceSection()
        case .language: LanguageSection()
        }
    }
}
