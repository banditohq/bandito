import BanditoDesign
import BanditoL10n
import SwiftUI

/// The language control of the top bar (Welcome only): a capsule with the language the interface runs in,
/// a list of the nine languages in a popover, and after a pick a hint with a restart button. The choice applies
/// at launch, as in Settings → Language.
struct OnboardingLanguageMenu: View {
    @State private var isOpen = false
    @State private var picked = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                isOpen = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .medium))
                    Text(InterfaceLanguage.current)
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.7)
                }
                .foregroundStyle(Color.Bandito.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.Bandito.text.opacity(isHovered ? 0.1 : 0.05), in: Capsule())
                .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .banditoAnimation(BanditoMotion.ease, value: isHovered)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                languageList
            }
            if picked {
                HStack(spacing: 10) {
                    Text(L10n.Settings.languageRestart)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                    Button(L10n.Terminals.restart) {
                        SystemActions.relaunch()
                    }
                    .buttonStyle(QuietButtonStyle(size: .regular))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.text.opacity(0.1)))
            }
        }
    }

    private var languageList: some View {
        VStack(spacing: 2) {
            ForEach(L10n.languages, id: \.code) { entry in
                let isCurrent = entry.code == (L10n.bundle.preferredLocalizations.first ?? "en")
                Button {
                    GeneralSection.storeLanguage(entry.code)
                    picked = true
                    isOpen = false
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.native)
                                .font(BanditoFont.font(size: 13.5, weight: 500))
                                .foregroundStyle(Color.Bandito.text)
                            Text(entry.code.uppercased())
                                .font(BanditoFont.font(size: 11, weight: 400))
                                .foregroundStyle(Color.Bandito.text3)
                        }
                        Spacer(minLength: 14)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.Bandito.signal)
                            .opacity(isCurrent ? 1 : 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(width: 220, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(LanguageRowStyle())
            }
        }
        .padding(8)
    }
}

/// A language row: a soft fill on hover, a slight dim while pressed.
private struct LanguageRowStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.Bandito.text.opacity(isHovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { isHovered = $0 }
    }
}
