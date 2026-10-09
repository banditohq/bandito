import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The sections of the Server mode, picked in its sidebar.
public enum ServerSection: String, CaseIterable, Identifiable, Sendable {
    case overview, workspaces, secrets, ports, devices, updates, journal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: L10n.Mode.serverOverview
        case .workspaces: L10n.Mode.serverWorkspaces
        case .secrets: L10n.Mode.serverSecrets
        case .ports: L10n.Mode.serverPorts
        case .devices: L10n.Mode.serverDevices
        case .updates: L10n.Mode.serverUpdates
        case .journal: L10n.Mode.serverJournal
        }
    }
}

/// Server mode: the host overview and the sections around it. The section in view comes from the sidebar.
struct ServerMode: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch router.serverSection {
            case .overview: ServerOverview(server: app.currentServer)
            case .workspaces: WorkspacesView()
            case .secrets: SecretsView(server: app.currentServer)
            case .ports: PortsView(server: app.currentServer)
            case .devices: DevicesView(server: app.currentServer)
            case .updates: UpdatesView(server: app.currentServer)
            case .journal: ServerJournalView(server: app.currentServer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: router.serverSection)
    }
}

/// Common frame of a Server section: title, controls on the right, then the content in a scroll view.
struct ServerPage<Trailing: View, Content: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(title: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 12)
                trailing
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension ServerPage where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// Shown instead of a feature the server does not have yet, or while it is not connected.
struct ServerUnavailable: View {
    let server: ServerModel?

    var body: some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(Color.Bandito.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .banditoCard()
    }

    private var message: String {
        guard let server else { return L10n.Server.noServer }
        return server.info == nil ? L10n.Server.notConnected : L10n.Server.updateNote
    }
}

/// Sidebar of the Server mode: the seven sections. Picking one sets `Router.serverSection`.
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

/// A rounded card of the Server screens, with the Bandito card surface.
struct ServerCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }
}
