import BanditoDesign
import BanditoL10n
import SwiftUI

/// Server → Workplaces. Sample data until the daemon has workspaces: the cards carry the "Example" chip,
/// and dragging an agent between them only moves it on this screen.
struct WorkspacesView: View {
    @Environment(DemoStore.self) private var demo
    /// Agent name → workplace name, for the drags made on this screen.
    @State private var moved: [String: String] = [:]

    var body: some View {
        ServerPage(title: L10n.Server.Workspaces.title) {
            Text(L10n.Server.Workspaces.intro)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 680, alignment: .leading)
            if demo.enabled {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(demo.spaces) { space in
                        WorkspaceCard(space: space, agents: agents(in: space)) { name in
                            moved[name] = space.name
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                compare
            } else {
                ServerCard {
                    Text(L10n.Server.Workspaces.demoOff)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
        }
    }

    /// Agents of a workplace: by default the ones the sample data puts there, then the ones dragged here.
    private func agents(in space: DemoSpace) -> [String] {
        let all = demo.spaces.flatMap(\.agents)
        return all.filter { name in
            if let target = moved[name] { return target == space.name }
            return space.agents.contains(name)
        }
    }

    private var compare: some View {
        ServerCard {
            SectionLabel(L10n.Server.Workspaces.compare)
            HStack(alignment: .top, spacing: 16) {
                CompareItem(
                    kind: .shared, title: L10n.Server.Workspaces.Compare.sharedTitle,
                    text: L10n.Server.Workspaces.Compare.sharedText, note: L10n.Server.Workspaces.Compare.sharedNote)
                CompareItem(
                    kind: .user, title: L10n.Server.Workspaces.Compare.userTitle,
                    text: L10n.Server.Workspaces.Compare.userText, note: L10n.Server.Workspaces.Compare.userNote)
                CompareItem(
                    kind: .container, title: L10n.Server.Workspaces.Compare.containerTitle,
                    text: L10n.Server.Workspaces.Compare.containerText,
                    note: L10n.Server.Workspaces.Compare.containerNote)
            }
        }
    }
}

extension DemoSpace.Kind {
    var tint: Color {
        switch self {
        case .shared: Color(hex: 0xFFB067)
        case .container: Color(hex: 0xA3BDEB)
        case .user: Color(hex: 0xF2A093)
        }
    }

    var icon: String {
        switch self {
        case .shared: "house"
        case .container: "shippingbox"
        case .user: "person"
        }
    }

    var label: String {
        switch self {
        case .shared: L10n.Server.Workspaces.Kind.shared
        case .container: L10n.Server.Workspaces.Kind.container
        case .user: L10n.Server.Workspaces.Kind.user
        }
    }
}

/// One workplace: its agents (draggable onto other cards) and what it can reach.
private struct WorkspaceCard: View {
    let space: DemoSpace
    let agents: [String]
    var onDrop: (String) -> Void

    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: space.kind.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(space.kind.tint)
                    .frame(width: 38, height: 38)
                    .background(space.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(space.name)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                    Text(space.kind.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(space.kind.tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(space.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Spacer(minLength: 6)
                ExampleChip()
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.Server.Workspaces.agents)
                HStack(spacing: 8) {
                    ForEach(agents, id: \.self) { name in
                        VStack(spacing: 3) {
                            AgentAvatar(name: name, size: 30)
                            Text(name)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.Bandito.text2)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 44)
                        .draggable(name)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(targeted ? space.kind.tint.opacity(0.08) : Color.Bandito.text.opacity(0.025)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            targeted ? space.kind.tint.opacity(0.7) : Color.Bandito.text.opacity(0.1),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .dropDestination(for: String.self) { items, _ in
                    guard let name = items.first else { return false }
                    withAnimation(.easeInOut(duration: 0.2)) { onDrop(name) }
                    return true
                } isTargeted: { targeted = $0 }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(space.rows, id: \.label) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: row.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Bandito.text3)
                            .frame(width: 15)
                        Text(row.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.Bandito.text3)
                            .frame(width: 74, alignment: .leading)
                        Text(row.value)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.Bandito.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !space.meters.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(space.meters, id: \.label) { meter in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(meter.label)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.Bandito.text3)
                                Spacer(minLength: 4)
                                Text(meter.value)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.Bandito.text)
                            }
                            MeterBar(fraction: meter.fraction, tint: space.kind.tint)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .banditoCard()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(space.kind.tint.opacity(targeted ? 0.6 : 0), lineWidth: 1.5))
    }
}

private struct CompareItem: View {
    let kind: DemoSpace.Kind
    let title: String
    let text: String
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(kind.tint)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xA9C7A2))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A thin bar showing how much of a limit is used.
struct MeterBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Bandito.text.opacity(0.08))
                Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 5)
    }
}
