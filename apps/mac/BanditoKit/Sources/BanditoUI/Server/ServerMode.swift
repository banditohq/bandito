import BanditoDesign
import BanditoL10n
import SwiftUI

/// The sections of the Server mode, picked in its sidebar.
public enum ServerSection: String, CaseIterable, Identifiable, Sendable {
    case overview, workspaces, secrets, ports

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: L10n.Mode.serverOverview
        case .workspaces: L10n.Mode.serverWorkspaces
        case .secrets: L10n.Mode.serverSecrets
        case .ports: L10n.Mode.serverPorts
        }
    }
}

/// Server mode: the host overview, workplaces, secrets and ports. The section in view comes from the sidebar.
struct ServerMode: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 14) {
            Text(router.serverSection.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Mode.soonHere)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
    }
}

/// Server sidebar: the four sections. Picking one sets `Router.serverSection`.
struct ServerSidebar: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ServerSection.allCases) { section in
                let selected = router.serverSection == section
                Button {
                    router.serverSection = section
                } label: {
                    Text(section.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selected ? Color.Bandito.text.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
