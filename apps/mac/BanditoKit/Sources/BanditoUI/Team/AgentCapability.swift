import BanditoDesign
import BanditoL10n
import SwiftUI

/// What an agent may do on the server, as the "What it may do" chips show it. The wire names are sent with
/// `agents.create` and `agents.update`. Until the daemon has the field it ignores them, so nothing is enforced yet.
public enum AgentCapability: String, CaseIterable, Identifiable, Sendable {
    /// The raw values are the wire names the daemon uses (`Agent.capabilities`).
    case terminal, files, browser, team, screen

    public var id: String { rawValue }

    /// Every capability on: what an agent may do when the daemon sends no list.
    public static let allOn: Set<AgentCapability> = Set(allCases)

    /// The set an agent's wire list stands for. `nil` (no list from the daemon) means everything; unknown names are
    /// ignored, so a newer daemon's capability does not break an older app.
    public static func set(from wire: [String]?) -> Set<AgentCapability> {
        guard let wire else { return allOn }
        return Set(wire.compactMap(AgentCapability.init(rawValue:)))
    }

    /// The wire list for a set, in the order of the chips.
    public static func wire(_ enabled: Set<AgentCapability>) -> [String] {
        allCases.filter(enabled.contains).map(\.rawValue)
    }

    /// The set after one chip is clicked: on becomes off and off becomes on. Other chips are not touched.
    public static func toggled(_ enabled: Set<AgentCapability>, _ capability: AgentCapability) -> Set<AgentCapability> {
        var next = enabled
        if next.contains(capability) {
            next.remove(capability)
        } else {
            next.insert(capability)
        }
        return next
    }

    public var title: String {
        switch self {
        case .terminal: L10n.Capability.terminal
        case .files: L10n.Capability.files
        case .browser: L10n.Capability.browser
        case .team: L10n.Capability.crew
        case .screen: L10n.Capability.screen
        }
    }
}

/// The capability chips. A chip is a switch: an on chip has a solid outline and a check, an off chip a dashed outline
/// and a plus. Chips wrap onto more lines when the window is narrow and never break their own text.
///
/// A click sends the whole list with `agents.update`. A daemon without the field ignores it, and the list comes back
/// as the daemon has it (all on), so the chips show that instead of the click.
struct CapabilityChips: View {
    @Binding var enabled: Set<AgentCapability>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(AgentCapability.allCases) { capability in
                chip(capability)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ capability: AgentCapability) -> some View {
        let on = enabled.contains(capability)
        return Button {
            enabled = AgentCapability.toggled(enabled, capability)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark" : "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(capability.title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(BanditoFont.font(size: 12.5, weight: 500))
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
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
