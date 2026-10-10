import BanditoDesign
import SwiftUI

/// Six icon buttons that switch the main window's mode. The selected one is a raised cell that slides between them.
struct ModeBar: View {
    @Environment(Router.self) private var router
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            // The Marketplace is opened from the sidebar footer, not from this bar.
            ForEach(AppMode.allCases.filter { $0 != .market }) { mode in
                ModeCell(mode: mode, selected: router.mode == mode, highlight: highlight) {
                    router.select(mode: mode)
                }
            }
        }
        .padding(3)
        .tourAnchor(.modes)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.Bandito.surface1))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.Bandito.text.opacity(0.09), Color.Bandito.text.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom)))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .banditoAnimation(.spring(response: 0.32, dampingFraction: 0.86), value: router.mode)
    }
}

/// One mode button. Inactive cells are muted and light up on hover; the selected cell is the raised pill.
private struct ModeCell: View {
    let mode: AppMode
    let selected: Bool
    let highlight: Namespace.ID
    let select: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            Image(systemName: mode.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.Bandito.surface3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.Bandito.text.opacity(0.10)))
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    } else if hovered {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.Bandito.text.opacity(0.04))
                    }
                }
                .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 10))
        .focusable(false)
        .onHover { hovered = $0 }
        .banditoAnimation(.easeOut(duration: 0.15), value: hovered)
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var iconColor: Color {
        if selected { return Color.Bandito.text }
        return hovered ? Color.Bandito.text2 : Color.Bandito.text3
    }
}
