import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Step 3 of 5 on screen: choose "This Mac" or "your server", watch the install, then see what the server has.
struct FirstServerStep: View {
    /// Goes on to the first agent.
    var onFinished: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(AccountHub.self) private var hub
    @State private var model = FirstServerModel()
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch model.phase {
            case .choosing:
                chooser
            case .installing:
                checklistView
            case .reviewingHost(let preview):
                hostReview(preview)
            case .failed:
                failureView
            case .connected(let config):
                connected(config)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .task {
            model.accountHub = hub
            let ssh = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh")
            let config = (try? String(contentsOf: ssh.appending(path: "config"), encoding: .utf8)) ?? ""
            let known = (try? String(contentsOf: ssh.appending(path: "known_hosts"), encoding: .utf8)) ?? ""
            model.loadSuggestions(config: config, knownHosts: known)
        }
    }

    // MARK: choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Onboarding.Server.title)
                .font(BanditoFont.font(size: 32, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Onboarding.Server.subtitle)
                .font(BanditoFont.font(size: 15, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            HStack(spacing: 12) {
                optionCard(
                    title: L10n.Onboarding.Server.onThisMac, text: L10n.Onboarding.Server.thisMacDesc,
                    selected: model.option == .thisMac
                ) {
                    model.startThisMac(app: app)
                }
                optionCard(
                    title: L10n.Onboarding.Server.ownServer, text: L10n.Onboarding.Server.ownServerDesc,
                    selected: model.option == .ownServer
                ) {
                    model.choose(.ownServer)
                }
            }
            if model.option == .ownServer {
                addressBlock
            }
            HStack(spacing: 6) {
                Text(L10n.Onboarding.Server.noServerDesc)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                Button(L10n.Onboarding.Server.getServer) {
                    SystemActions.open(URL(string: "https://bandito.dev/guide/server")!)
                }
                .buttonStyle(.plain)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.signal)
            }
        }
    }

    private func optionCard(title: String, text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(BanditoFont.font(size: 16, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(text)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? Color.Bandito.signal : Color.Bandito.text.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Onboarding.Server.addressTitle)
                .font(BanditoFont.font(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            HStack(spacing: 8) {
                TextField("user@host:22", text: $model.address)
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 14, weight: 400, mono: true))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.Bandito.text.opacity(0.12)))
                    .onSubmit { model.startOwnServer(app: app) }
                Button(L10n.Onboarding.Server.connect) { model.startOwnServer(app: app) }
                    .buttonStyle(SignalButtonStyle())
            }
            if let addressError = model.addressError {
                Text(addressError)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            if !model.suggestions.isEmpty {
                Text(L10n.Onboarding.Server.foundInConfig)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                HStack(spacing: 6) {
                    ForEach(model.suggestions.prefix(6), id: \.self) { host in
                        Button(host) { model.address = host }
                            .buttonStyle(QuietButtonStyle(size: .regular))
                    }
                }
            }
            Text(L10n.Onboarding.Server.addressHint(path: "~/.ssh"))
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineSpacing(2)
        }
    }

    // MARK: installing

    private var checklistView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Onboarding.Server.installingTitle)
                .font(BanditoFont.font(size: 26, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            ForEach(ChecklistItem.allCases, id: \.self) { item in
                HStack(spacing: 12) {
                    markView(model.checklist.mark(of: item))
                    Text(itemTitle(item))
                        .font(BanditoFont.font(size: 14.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                }
                .banditoAnimation(BanditoMotion.ease, value: model.checklist.mark(of: item))
            }
            DisclosureGroup(L10n.Onboarding.Server.showLog, isExpanded: $showLog) {
                ScrollView {
                    Text(model.checklist.log.joined(separator: "\n"))
                        .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 140)
            }
            .font(BanditoFont.font(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.text2)
        }
    }

    @ViewBuilder
    private func markView(_ mark: ChecklistMark) -> some View {
        switch mark {
        case .pending:
            Circle().stroke(Color.Bandito.text.opacity(0.2), lineWidth: 1.5).frame(width: 16, height: 16)
        case .running:
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(AvatarColor.sage.color)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.Bandito.danger)
        }
    }

    private func itemTitle(_ item: ChecklistItem) -> String {
        switch item {
        case .connect: L10n.Onboarding.Install.connect
        case .check: L10n.Onboarding.Install.check
        case .install: L10n.Onboarding.Install.install
        case .service: L10n.Onboarding.Install.service
        case .app: L10n.Onboarding.Install.app
        }
    }

    // MARK: host review

    private func hostReview(_ preview: HostKeyPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.Server.fingerprintTitle)
                .font(BanditoFont.font(size: 24, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Onboarding.Server.keyType(type: preview.keyType))
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
            Text(preview.fingerprint)
                .font(BanditoFont.font(size: 16, weight: 600, mono: true))
                .foregroundStyle(Color.Bandito.text)
                .textSelection(.enabled)
                .padding(14)
                .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
            Text(L10n.Onboarding.Server.fingerprintHint)
                .font(BanditoFont.font(size: 13.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            HStack(spacing: 10) {
                Button(L10n.Onboarding.Server.trustHost) {
                    Task { await model.trustHost(preview, app: app) }
                }
                .buttonStyle(SignalButtonStyle())
                Button(L10n.Common.cancel) { model.backToChoice() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    // MARK: failure

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.Server.failedTitle)
                .font(BanditoFont.font(size: 24, weight: 600))
                .foregroundStyle(Color.Bandito.danger)
            if let failure = model.failure {
                Text(Self.failureText(failure))
                    .font(BanditoFont.font(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                failureActions(failure)
            }
            if let hostKeyError = model.hostKeyError {
                Text(hostKeyError)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            if let command = model.knownHostCommand {
                Text(L10n.Onboarding.Server.removeOldKey)
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                HStack(spacing: 10) {
                    Text(command)
                        .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                    Button(L10n.Onboarding.Server.copy) { SystemActions.copy(command) }
                        .buttonStyle(QuietButtonStyle(size: .regular))
                }
            }
            if let command = model.proxyCommand {
                HStack(spacing: 10) {
                    Text(command)
                        .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                    Button(L10n.Onboarding.Server.copy) { SystemActions.copy(command) }
                        .buttonStyle(QuietButtonStyle(size: .regular))
                }
            }
            Button(L10n.Onboarding.Server.back) { model.backToChoice() }
                .buttonStyle(QuietButtonStyle())
        }
    }

    @ViewBuilder
    private func failureActions(_ failure: InstallError) -> some View {
        if case .sshFailed(.hostKeyUnknown) = failure {
            Button(L10n.Onboarding.Server.reviewHost) { Task { await model.reviewHost() } }
                .buttonStyle(SignalButtonStyle())
        } else if case .sshFailed(.keyNotAccepted) = failure, let command = Self.copyKeyCommand(model.address) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Onboarding.Server.copyKeyHint)
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                HStack(spacing: 10) {
                    Text(command)
                        .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                    Button(L10n.Onboarding.Server.copy) { SystemActions.copy(command) }
                        .buttonStyle(QuietButtonStyle(size: .regular))
                }
                Button(L10n.Onboarding.Server.retry) { model.startOwnServer(app: app) }
                    .buttonStyle(SignalButtonStyle())
            }
        } else if model.option == .ownServer {
            Button(L10n.Onboarding.Server.retry) { model.startOwnServer(app: app) }
                .buttonStyle(SignalButtonStyle())
        } else {
            Button(L10n.Onboarding.Server.retry) { model.startThisMac(app: app) }
                .buttonStyle(SignalButtonStyle())
        }
    }

    /// The text for an install failure, from the reason ssh gave (never raw stderr).
    static func failureText(_ failure: InstallError) -> String {
        switch failure {
        case .sshFailed(let reason):
            switch reason {
            case .hostKeyUnknown: return L10n.Onboarding.Server.Err.hostUnknown
            case .hostKeyChanged: return L10n.Onboarding.Server.Err.hostChanged
            case .keyNotAccepted: return L10n.Onboarding.Server.Err.keyNotAccepted
            case .unknownHost: return L10n.Onboarding.Server.Err.unknownHost
            case .refused: return L10n.Onboarding.Server.Err.refused
            case .timedOut: return L10n.Onboarding.Server.Err.timedOut
            case .noRoute: return L10n.Onboarding.Server.Err.noRoute
            case .other: return L10n.Onboarding.Server.Err.generic
            }
        case .unsupportedPlatform: return L10n.Onboarding.Server.Err.unsupported
        case .localBinaryMissing: return L10n.Onboarding.Server.Err.localBinary
        default: return L10n.Onboarding.Server.Err.generic
        }
    }

    /// `ssh-copy-id [-p N] user@host`, built from the validated target only.
    static func copyKeyCommand(_ address: String) -> String? {
        guard let target = SSHTarget.parse(address) else { return nil }
        let port = target.port.map { " -p \($0)" } ?? ""
        return "ssh-copy-id\(port) \(target.destination)"
    }

    // MARK: connected

    private func connected(_ config: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.Server.connectedTitle)
                .font(BanditoFont.font(size: 26, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(config.name)
                .font(BanditoFont.font(size: 14, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            if let syncError = model.syncError {
                HStack(spacing: 10) {
                    Text(syncError)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                    Button(L10n.Onboarding.Server.retry) { model.syncServers(app: app) }
                        .buttonStyle(QuietButtonStyle(size: .regular))
                }
            }
            componentsBlock(config)
            Button(L10n.Onboarding.Server.nextAgent, action: onFinished)
                .buttonStyle(SignalButtonStyle())
        }
    }

    private func componentsBlock(_ config: ServerConfig) -> some View {
        let server = app.servers.first { $0.id == config.id }
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Onboarding.Server.componentsTitle)
                .font(BanditoFont.font(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            ForEach(model.setup.lines) { line in
                HStack {
                    Text(line.title)
                        .font(BanditoFont.font(size: 13.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                    Spacer()
                    let ready = line.state == .ready
                    Text(ready ? L10n.Onboarding.Server.componentReady : L10n.Onboarding.Server.componentMissing)
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .foregroundStyle(ready ? AvatarColor.sage.color : Color.Bandito.text3)
                }
            }
            if model.setup.error != nil {
                Text(L10n.Onboarding.Server.componentsFailed)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            if let command = model.setup.passwordCommand, let server {
                passwordCard(command: command, server: server)
            } else if let server, !model.setup.missingInstallable.isEmpty, !model.setup.isRunning {
                Button(L10n.Onboarding.Server.installMissing) {
                    Task { await model.setup.install(model.setup.missingInstallable, server: server) }
                }
                .buttonStyle(QuietButtonStyle())
            }
            if let server {
                Button(L10n.Onboarding.Server.checkAgain) {
                    Task { await model.setup.load(server) }
                }
                .buttonStyle(.plain)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.signal)
            }
        }
        .padding(16)
        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.Bandito.text.opacity(0.1)))
    }

    /// The administrator password is never asked for or kept by Bandito: the person runs the command in a terminal.
    private func passwordCard(command: String, server: ServerModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Onboarding.Server.passwordHint)
                .font(BanditoFont.font(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            HStack(spacing: 10) {
                Text(command)
                    .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
                    .foregroundStyle(Color.Bandito.text)
                    .textSelection(.enabled)
                Button(L10n.Onboarding.Server.copy) { SystemActions.copy(command) }
                    .buttonStyle(QuietButtonStyle(size: .regular))
            }
            Button(L10n.Onboarding.Server.doneCheckAgain) {
                Task { await model.setup.load(server) }
            }
            .buttonStyle(SignalButtonStyle())
        }
    }
}
