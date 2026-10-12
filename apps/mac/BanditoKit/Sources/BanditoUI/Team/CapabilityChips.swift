import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The capability chips. A chip is a switch: an on chip has a solid outline and a check, an off chip a dashed outline
/// and a plus. Chips wrap onto more lines when the window is narrow and never break their own text.
///
/// A click sends the whole list with `agents.update`. A daemon without the field ignores it, and the list comes back
/// as the daemon has it (all on), so the chips show that instead of the click.
struct CapabilityChips: View {
    @Binding var enabled: Set<AgentCapability>
    /// The chips the server cannot give, with the reason each shows as its help. Such a chip is disabled and does not
    /// react to a click. Empty by default, so a caller without a server to ask keeps every chip live.
    var unavailable: [AgentCapability: String] = [:]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(AgentCapability.allCases) { capability in
                chip(capability)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func chip(_ capability: AgentCapability) -> some View {
        let on = enabled.contains(capability)
        let reason = unavailable[capability]
        let button = Button {
            enabled = AgentCapability.toggled(enabled, capability)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark" : "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(capability.title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(on ? Color.Bandito.text : Color.Bandito.text3)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(on ? Color.Bandito.text.opacity(0.06) : Color.clear, in: Capsule())
            .overlay {
                if on {
                    Capsule().stroke(Color.Bandito.line, lineWidth: 1)
                } else {
                    Capsule().stroke(
                        Color.Bandito.text.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(Capsule())
        }
        .banditoButton(.row(cornerRadius: 15, hoverOpacity: 0.04))
        .disabled(reason != nil)
        .accessibilityAddTraits(on ? .isSelected : [])
        if let reason {
            button.help(reason)
        } else {
            button
        }
    }
}
