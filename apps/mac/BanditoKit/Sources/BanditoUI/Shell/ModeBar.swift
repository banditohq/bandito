import BanditoDesign
import SwiftUI

/// Six icon buttons that switch the main window's mode. The selected one is a pill that slides between them.
struct ModeBar: View {
    @Environment(Router.self) private var router
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppMode.allCases) { mode in
                let selected = router.mode == mode
                Button {
                    router.select(mode: mode)
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text3)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.Bandito.surface3)
                                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.Bandito.text.opacity(0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.Bandito.text.opacity(0.06)))
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .banditoAnimation(.spring(response: 0.32, dampingFraction: 0.86), value: router.mode)
    }
}
