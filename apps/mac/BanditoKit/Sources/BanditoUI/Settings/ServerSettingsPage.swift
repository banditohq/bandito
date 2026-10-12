import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Servers → one server. Its name at the top, then the sections of its settings. This page holds the agents
/// by default, the maintenance and the facts of the server; the server's main settings and its connection have their
/// own sections on it later.
struct ServerSettingsPage: View {
    let server: ServerModel
    let onBack: () -> Void
    @State private var model: ServerSettingsModel

    /// `preview` and `previewStats` show the given values without a connection (the layout audit); a live page reads
    /// them from the server.
    init(
        server: ServerModel, onBack: @escaping () -> Void,
        preview: ServerSettingsSnapshot? = nil, previewStats: HostStats? = nil
    ) {
        self.server = server
        self.onBack = onBack
        _model = State(initialValue: ServerSettingsModel(server: server, snapshot: preview, stats: previewStats))
    }

    /// Reads the settings again when the server reports a change or connects.
    private struct LoadKey: Hashable {
        let revision: Int
        let connected: Bool
    }

    var body: some View {
        SettingsPage(title: server.config.name, intro: L10n.ServerSettings.intro, titleLines: 2) {
            backRow
            saveStatus
            notice
            ServerMainSection(server: server)
            ServerConnectionSection(server: server, onBack: onBack)
            ServerAgentDefaultsSection(server: server, model: model)
            ServerMaintenanceSection(server: server, model: model)
            ServerInfoSection(server: server, model: model)
        }
        .task(id: LoadKey(revision: server.settingsRevision, connected: server.info != nil)) {
            guard server.supports("server_settings") else { return }
            await model.load()
        }
        .task(id: server.info != nil) {
            guard server.supports("host") else { return }
            await model.loadStats()
        }
    }

    private var backRow: some View {
        Button(action: onBack) {
            Label(L10n.ServerSettings.back, systemImage: "chevron.left")
        }
        .banditoButton(.link)
        .fixedSize()
    }

    /// What the last change did: saving, saved, or refused. Nothing before the first change.
    @ViewBuilder private var saveStatus: some View {
        switch model.saveState {
        case .idle:
            EmptyView()
        case .saving:
            Chip(text: L10n.ServerSettings.saving).fixedSize()
        case .saved:
            Chip(text: L10n.ServerSettings.saved, tone: .ok).fixedSize()
        case .failed:
            Text(L10n.ServerSettings.saveFailed)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Why the settings rows are missing: an older server, or a connection that did not answer.
    @ViewBuilder private var notice: some View {
        if !server.supports("server_settings") {
            Text(L10n.ServerSettings.unsupported)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.loadFailed {
            Text(L10n.ServerSettings.loadFailed)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
