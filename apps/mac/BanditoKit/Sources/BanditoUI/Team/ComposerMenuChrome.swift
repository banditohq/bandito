import BanditoDesign
import SwiftUI

// The look the two menus above the composer share: the `/` menu (`SlashMenuView`) and the `@` menu
// (`MentionMenuView`). One surface, one group title, one selected row, one footer.

/// The raised panel of a menu above the composer.
struct ComposerMenuSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 640)
            .background(Color(hex: 0x201C18).opacity(0.98), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.Bandito.text.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 14)
    }
}

/// A row's frame: the peach wash and edge while it is the selected one.
struct ComposerMenuRowFrame: ViewModifier {
    var selected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                selected ? BanditoPalette.peach.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? BanditoPalette.peach.opacity(0.3) : Color.clear))
            .contentShape(Rectangle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    func composerMenuSurface() -> some View { modifier(ComposerMenuSurface()) }
    func composerMenuRow(selected: Bool) -> some View { modifier(ComposerMenuRowFrame(selected: selected)) }
}

/// The small caps line above a group of rows.
struct ComposerMenuGroupTitle: View {
    var text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.text(size: 10.5, weight: 600))
            .tracking(0.8)
            .foregroundStyle(Color.Bandito.text3)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

/// The line of key hints at the bottom, with room for a trailing control.
struct ComposerMenuFooter<Trailing: View>: View {
    var hints: [String]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            ForEach(hints, id: \.self) { Text($0) }
            Spacer(minLength: 8)
            trailing
        }
        .font(BanditoFont.text(size: 11.5, weight: 400))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.text.opacity(0.07)).frame(height: 1)
        }
    }
}
