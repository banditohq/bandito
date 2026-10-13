import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// «Подключить iPhone» from the profile's Devices: picks the server (skipped when there is one), turns the cloud on by
/// itself, shows the QR code, waits for the phone, and says it is done. No questions between.
struct ConnectPhoneWizard: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var model: ConnectPhoneModel?
    /// A state to show without asking anybody (the layout audit and the screenshots).
    var preview: ConnectPhoneModel.Step?
    var previewServerName: String = ""
    var previewServers: [String] = []

    var body: some View {
        VStack(spacing: 18) {
            Text(L10n.PhoneWizard.title)
                .font(BanditoFont.display(size: 15.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content
            actions
        }
        .padding(26)
        .frame(width: 420)
        .background(Color.Bandito.surface2)
        .task { await begin() }
        .onChange(of: model?.step) { _, step in
            // The cloud is on and the code shows: tell the account at once, so the iPhone that signs in finds the server.
            if case .scan = step { hub.requestAccessCycle() }
        }
        .onDisappear { model?.cancel() }
    }

    private var step: ConnectPhoneModel.Step? { preview ?? model?.step }

    @ViewBuilder private var content: some View {
        switch step {
        case nil:
            preparing(.enabling)
        case .pickServer:
            pick
        case .preparing(let detail):
            preparing(detail)
        case .scan(let state):
            scan(state)
        case .done(let device):
            done(device: device)
        case .problem(let problem):
            problemView(problem)
        }
    }

    // MARK: Steps

    private var pick: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.PhoneWizard.Pick.title)
                .font(BanditoFont.text(size: 13.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.PhoneWizard.Pick.hint)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(choices) { choice in
                    Button {
                        if let server = model?.servers.first(where: { $0.wizardID == choice.id }) { model?.choose(server) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.Bandito.text2)
                                .frame(width: 28, height: 28)
                                .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(choice.name)
                                .font(BanditoFont.text(size: 13, weight: 500))
                                .foregroundStyle(Color.Bandito.text)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.Bandito.text3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .banditoButton(.row(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var choices: [ServerChoice] {
        if !previewServers.isEmpty { return previewServers.map { ServerChoice(id: UUID(), name: $0) } }
        return model?.servers.map { ServerChoice(id: $0.wizardID, name: $0.wizardName) } ?? []
    }

    private func preparing(_ detail: CloudAccessRules.Status) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text(L10n.PhoneWizard.preparing)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
            Text(detailText(detail))
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func detailText(_ detail: CloudAccessRules.Status) -> String {
        switch detail {
        case .connecting: L10n.ServerSettings.Phone.Cloud.connecting
        default: L10n.ServerSettings.Phone.Cloud.enabling
        }
    }

    @ViewBuilder private func scan(_ state: PhoneAccessRules.PairState) -> some View {
        switch state {
        case .ready(let link, let code, _, let minutes, _):
            VStack(spacing: 14) {
                Text(L10n.ServerSettings.Phone.Pair.steps)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                QRCodeView(text: link, size: 200)
                Label(L10n.PhoneWizard.via, systemImage: "cloud.fill")
                    .font(BanditoFont.text(size: 12, weight: 600))
                    .foregroundStyle(Color.Bandito.signal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.Bandito.signal.opacity(0.14), in: Capsule())
                VStack(spacing: 4) {
                    Text(L10n.ServerSettings.Phone.Pair.codeLabel)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    Text(code)
                        .font(BanditoFont.mono(size: 16, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.ServerSettings.Phone.Pair.expires(minutes: String(minutes)))
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.PhoneWizard.waiting)
                        .font(BanditoFont.text(size: 12.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                }
                if hub.signedIn {
                    Text(L10n.PhoneWizard.orSignIn)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    SystemActions.open(IPhoneApp.requestInvite)
                } label: {
                    Text(L10n.PhoneWizard.install)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .banditoButton(.link)
            }
        case .expired:
            text(L10n.ServerSettings.Phone.Pair.expired)
        case .notListening:
            text(L10n.ServerSettings.Phone.Pair.notListening)
        case .updateApp:
            text(L10n.ServerSettings.Phone.Pair.updateApp)
        case .invalid:
            text(L10n.ServerSettings.Phone.Pair.invalid)
        }
    }

    private func done(device: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.Bandito.bg)
                .frame(width: 56, height: 56)
                .background(Color.Bandito.ok, in: Circle())
                .accessibilityHidden(true)
            Text(L10n.PhoneWizard.Done.title)
                .font(BanditoFont.display(size: 14.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            text(L10n.PhoneWizard.Done.body(device: device, server: model?.chosen?.wizardName ?? previewServerName))
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func problemView(_ problem: ConnectPhoneModel.Problem) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(Color.Bandito.text3)
                .accessibilityHidden(true)
            switch problem {
            case .noServer: text(L10n.PhoneWizard.noServer)
            case .needsSignIn: text(L10n.PhoneWizard.signIn)
            case .message(let message): UserFacingErrorView(message: message)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .font(BanditoFont.text(size: 13, weight: 400))
            .foregroundStyle(Color.Bandito.text2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        ActionRow {
            switch step {
            case .scan(let state):
                if case .ready = state {
                    Button(L10n.ServerSettings.Phone.Pair.new) { model?.newCode() }
                        .banditoButton(.quiet())
                        .fixedSize()
                } else {
                    Button(L10n.ServerSettings.Phone.Pair.new) { model?.newCode() }
                        .banditoButton(.signal())
                        .fixedSize()
                }
                Button(L10n.Common.close) { dismiss() }
                    .banditoButton(.quiet())
                    .fixedSize()
            case .done:
                Button(L10n.PhoneWizard.Done.action) { dismiss() }
                    .banditoButton(.signal())
                    .fixedSize()
            case .problem:
                Button(L10n.PhoneWizard.retry) { model?.retry() }
                    .banditoButton(.quiet())
                    .fixedSize()
                Button(L10n.Common.close) { dismiss() }
                    .banditoButton(.signal())
                    .fixedSize()
            default:
                Button(L10n.Common.close) { dismiss() }
                    .banditoButton(.quiet())
                    .fixedSize()
            }
        }
    }

    private struct ServerChoice: Identifiable {
        let id: UUID
        let name: String
    }

    private func begin() async {
        guard preview == nil, model == nil else { return }
        let hub = hub
        let made = ConnectPhoneModel(
            candidates: app.servers,
            makeController: { server in
                RelayController(
                    host: server,
                    registrar: { [hub] in
                        guard await hub.signedIn else { return nil }
                        return try await hub.prepare()
                    })
            })
        model = made
        made.start()
    }
}
