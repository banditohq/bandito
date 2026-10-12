import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Servers → one server → Connection: the address the app reaches the server at (the ssh fields, or the
/// WebSocket address), a check of the link, reconnecting, switching the server off for a while, and removing it from
/// the app. Nothing here changes the server itself.
struct ServerConnectionSection: View {
    let server: ServerModel
    let onBack: () -> Void
    @Environment(AppModel.self) private var app
    @FocusState private var focus: Field?
    @State private var host = ""
    @State private var user = ""
    @State private var port = ""
    @State private var keyFile: String?
    @State private var address = ""
    /// The reason the last edit was not saved, in one sentence. nil when everything is valid.
    @State private var problem: String?
    @State private var check: CheckState = .idle
    @State private var confirmRemove = false

    private enum Field: Hashable {
        case host, user, port, address
    }

    private enum CheckState: Equatable {
        case idle, working, answered(milliseconds: Int), failed(String)
    }

    var body: some View {
        SettingsGroup(title: L10n.ServerSettings.Connection.title) {
            switch server.config.endpoint {
            case .ssh:
                sshRows
            case .webSocket:
                webSocketRow
            case .local:
                SettingsRow(
                    title: L10n.ServerSettings.Connection.ThisMac.title, hint: L10n.ServerSettings.Connection.ThisMac.hint
                ) {
                    EmptyView()
                }
            }
            if let problem {
                Text(problem)
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().padding(.horizontal, 16)
            checkRow
            Divider().padding(.horizontal, 16)
            reconnectRow
            Divider().padding(.horizontal, 16)
            disabledRow
            Divider().padding(.horizontal, 16)
            removeRow
        }
        .onAppear(perform: loadFields)
        .onChange(of: server.config.endpoint) { _, _ in loadFields() }
        // A field that loses focus is saved, as the Enter key saves it.
        .onChange(of: focus) { old, _ in
            if old != nil { commit() }
        }
        .confirmationDialog(
            L10n.ServerSettings.Connection.Remove.confirmTitle(name: server.config.name),
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button(L10n.ServerSettings.Connection.Remove.button, role: .destructive) {
                app.remove(server.id)
                onBack()
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ServerSettings.Connection.Remove.message)
        }
    }

    // MARK: Address

    @ViewBuilder private var sshRows: some View {
        SettingsRow(title: L10n.ServerSettings.Connection.Host.title, hint: L10n.ServerSettings.Connection.Host.hint) {
            field(text: $host, placeholder: L10n.ServerSettings.Connection.Host.placeholder, id: .host)
                .frame(minWidth: 160, maxWidth: 260)
        }
        Divider().padding(.horizontal, 16)
        SettingsRow(title: L10n.ServerSettings.Connection.User.title, hint: L10n.ServerSettings.Connection.User.hint) {
            field(text: $user, placeholder: L10n.ServerSettings.Connection.User.placeholder, id: .user)
                .frame(minWidth: 120, maxWidth: 200)
        }
        Divider().padding(.horizontal, 16)
        SettingsRow(title: L10n.ServerSettings.Connection.Port.title, hint: L10n.ServerSettings.Connection.Port.hint) {
            field(text: $port, placeholder: L10n.ServerSettings.Connection.Port.placeholder, id: .port)
                .frame(width: 96)
        }
        Divider().padding(.horizontal, 16)
        SettingsRow(
            title: L10n.ServerSettings.Connection.Key.title,
            hint: keyFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L10n.ServerSettings.Connection.Key.none
        ) {
            HStack(spacing: 8) {
                Button(L10n.ServerSettings.Connection.Key.choose, action: chooseKey)
                    .banditoButton(.quiet())
                    .fixedSize()
                if keyFile != nil {
                    Button(L10n.ServerSettings.Connection.Key.clear) {
                        keyFile = nil
                        commit()
                    }
                    .banditoButton(.quiet())
                    .fixedSize()
                }
            }
        }
    }

    private var webSocketRow: some View {
        SettingsRow(
            title: L10n.ServerSettings.Connection.Address.title, hint: L10n.ServerSettings.Connection.Address.hint
        ) {
            field(text: $address, placeholder: L10n.ServerSettings.Connection.Address.placeholder, id: .address)
                .frame(minWidth: 180, maxWidth: 300)
        }
    }

    private func field(text: Binding<String>, placeholder: String, id: Field) -> some View {
        TextField(placeholder, text: text)
            .banditoField()
            .font(BanditoFont.text(size: 13, weight: 400))
            .focused($focus, equals: id)
            .onSubmit(commit)
    }

    // MARK: Check, reconnect, off, remove

    private var checkRow: some View {
        SettingsRow(title: L10n.ServerSettings.Connection.Check.title, hint: checkText) {
            Button(L10n.ServerSettings.Connection.Check.button) {
                Task { await runCheck() }
            }
            .banditoButton(.quiet())
            .fixedSize()
            .disabled(check == .working)
        }
    }

    private var reconnectRow: some View {
        SettingsRow(title: L10n.ServerSettings.Connection.Reconnect.title, hint: L10n.ServerSettings.Connection.Reconnect.hint) {
            Button(L10n.ServerSettings.Connection.Reconnect.button) {
                Task { await app.reconnectServer(server.id) }
            }
            .banditoButton(.quiet())
            .fixedSize()
            .disabled(server.config.disabled)
        }
    }

    private var disabledRow: some View {
        SettingsRow(
            title: L10n.ServerSettings.Connection.Off.title, hint: L10n.ServerSettings.Connection.Off.hint,
            keepsControlBeside: true
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { server.config.disabled },
                    set: { off in Task { await app.setServerDisabled(server.id, off) } })
            )
            .labelsHidden()
            .toggleStyle(BanditoToggleStyle())
        }
    }

    private var removeRow: some View {
        SettingsRow(title: L10n.ServerSettings.Connection.Remove.title, hint: L10n.ServerSettings.Connection.Remove.hint) {
            Button(L10n.ServerSettings.Connection.Remove.button) {
                confirmRemove = true
            }
            .banditoButton(.quiet(tone: .danger))
            .fixedSize()
        }
    }

    private var checkText: String? {
        switch check {
        case .idle: L10n.ServerSettings.Connection.Check.hint
        case .working: L10n.ServerSettings.Connection.Check.working
        case .answered(let milliseconds): L10n.ServerSettings.Connection.Check.answered(milliseconds: String(milliseconds))
        case .failed(let text): text
        }
    }

    // MARK: Actions

    /// The fields show what the server's address is now (also after a save and after another client changed it).
    private func loadFields() {
        switch server.config.endpoint {
        case .ssh(let ssh, _):
            host = ssh.host
            user = ssh.user ?? ""
            port = ssh.port.map(String.init) ?? ""
            keyFile = ssh.identityFile
        case .webSocket(let url):
            address = url.absoluteString
        case .local:
            break
        }
        problem = nil
    }

    private func chooseKey() {
        guard let url = FilePanels.keyFileURL(message: L10n.ServerSettings.Connection.Key.message) else { return }
        keyFile = url.path
        commit()
    }

    /// Checks the typed fields and saves them when they are valid and different. A save reconnects the server, since
    /// the new address is the one the next connection uses. An invalid field keeps what was typed and says why.
    private func commit() {
        switch server.config.endpoint {
        case .ssh(let current, _):
            switch SSHServerAddress.validated(host: host, user: user, port: port, identityFile: keyFile) {
            case .failure(let failure):
                problem = Self.problemText(failure)
            case .success(let next):
                problem = nil
                guard next != current, let endpoint = ServerEndpointRules.replacingSSH(server.config.endpoint, with: next)
                else { return }
                save(endpoint)
            }
        case .webSocket(let current):
            guard let url = ServerEndpointRules.webSocketURL(address) else {
                problem = L10n.ServerSettings.Connection.Problem.url
                return
            }
            problem = nil
            guard url != current else { return }
            save(.webSocket(url: url))
        case .local:
            break
        }
    }

    private func save(_ endpoint: ServerEndpoint) {
        app.changeServer(server.id) { $0.endpoint = endpoint }
        Task { await app.reconnectServer(server.id) }
    }

    private func runCheck() async {
        check = .working
        switch await server.checkConnection() {
        case .answered(let milliseconds):
            check = .answered(milliseconds: milliseconds)
        case .failed(let kind):
            check = .failed(UserFacingError.message(for: kind).text)
        }
    }

    private static func problemText(_ problem: SSHServerAddress.Problem) -> String {
        switch problem {
        case .host: L10n.ServerSettings.Connection.Problem.host
        case .user: L10n.ServerSettings.Connection.Problem.user
        case .port: L10n.ServerSettings.Connection.Problem.port
        case .identityFile: L10n.ServerSettings.Connection.Problem.identityFile
        }
    }
}
