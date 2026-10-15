import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// «Добавить iPhone или iPad» from the profile's Devices. When the account can sign a phone in, the join code shows at
/// once, with no server to choose: the phone access is turned on in the background on every server that can take it,
/// and one quiet line says what that did. Otherwise (or by «Использовать код подключения») it is the pairing path: pick
/// the server (skipped when there is one), turn the cloud on, show the code, wait for the phone, and say it is done.
struct ConnectPhoneWizard: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: ConnectPhoneModel?
    /// Signed in, approved and holding the sync key: the iPhone can sign in with a scan (`JoinQRModel`) instead of the
    /// pairing code. The pairing code stays one click away, and the cloud access the wizard prepares is the same.
    @State private var joinAllowed = false
    /// The check above has an answer: until then the scan step waits instead of showing a code that may be swapped.
    @State private var joinChecked = false
    @State private var useJoin = true
    @State private var joinModel: JoinQRModel?
    /// The phone access turned on in the background for the join code (nil on the pairing path).
    @State private var warmup: PhoneAccessWarmup?
    /// One cloud controller per server for both paths, so the join path's background access and the pairing path never
    /// register the same server twice.
    @State private var relays = SharedRelayControllers()
    /// The wizard went away: a join model made after that is closed at once.
    @State private var disappeared = false
    /// The task that makes the join model; cancelled when the wizard goes away.
    @State private var joinTask: Task<Void, Never>?
    /// The join model to show without asking anybody (the layout audit and the screenshots).
    var previewJoin: JoinQRModel?
    /// A state to show without asking anybody (the layout audit and the screenshots).
    var preview: ConnectPhoneModel.Step?
    /// The line under the join code to show without asking anybody (the screenshots).
    var previewAccess: PhoneAccessWarmup.Summary?
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
        .animation(reduceMotion ? nil : BanditoMotion.ease, value: joinModel?.phase)
        .onDisappear {
            disappeared = true
            joinTask?.cancel()
            warmup?.cancel()
            model?.cancel()
            joinModel?.close()
        }
    }

    /// The model whose code is on screen, when the join code is the one shown.
    private var shownJoin: JoinQRModel? {
        if let previewJoin { return previewJoin }
        return joinAllowed && useJoin ? joinModel : nil
    }

    /// The join code is what the wizard shows: a preview, or the account can sign a phone in and the pairing code was
    /// not asked for.
    private var isJoinShown: Bool {
        previewJoin != nil || (joinChecked && joinAllowed && useJoin)
    }

    private var step: ConnectPhoneModel.Step? { preview ?? model?.step }

    @ViewBuilder private var content: some View {
        if isJoinShown {
            joinScan
        } else if !joinChecked, preview == nil {
            preparing(.connecting)
        } else {
            switch step {
            case nil:
                preparing(.enabling)
            case .pickServer:
                pick
            case .preparing(let detail):
                preparing(detail)
            case .scan(let state):
                pairScan(state)
            case .done(let device):
                done(device: device)
            case .problem(let problem):
                problemView(problem)
            }
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

    /// The join code in place of the pairing code (the person is signed in here): the iPhone signs in by scanning it.
    /// Under it, one quiet line about the phone access on the servers.
    @ViewBuilder private var joinScan: some View {
        VStack(spacing: 14) {
            if let shownJoin {
                JoinQRContent(model: shownJoin)
            } else {
                preparing(.connecting)
            }
            accessLine
            if previewJoin == nil {
                Button(L10n.PhoneWizard.usePairCode) { leaveJoin() }
                    .banditoButton(.link)
                    .font(BanditoFont.text(size: 12, weight: 400))
            }
        }
    }

    /// What the phone access did on the servers: a failure says which, with "Try again" in the same line.
    @ViewBuilder private var accessLine: some View {
        if let summary = previewAccess ?? warmup?.summary {
            let failed: Bool = {
                if case .failed = summary { return true }
                return false
            }()
            HStack(spacing: BanditoSpace.s2) {
                Text(Self.accessText(summary))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(failed ? Color.Bandito.danger : Color.Bandito.text3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if failed {
                    Button(L10n.PhoneWizard.retry) { warmup?.retry() }
                        .banditoButton(.link)
                        .font(BanditoFont.text(size: 12, weight: 500))
                        .fixedSize()
                }
            }
        }
    }

    static func accessText(_ summary: PhoneAccessWarmup.Summary) -> String {
        switch summary {
        case .noServers: L10n.PhoneWizard.noServer
        case .enabling: L10n.PhoneWizard.Access.enabling
        case .ready(let names): L10n.PhoneWizard.Access.ready(names: names.joined(separator: ", "))
        case .failed(let names): L10n.PhoneWizard.Access.failed(names: names.joined(separator: ", "))
        }
    }

    @ViewBuilder private func pairScan(_ state: PhoneAccessRules.PairState) -> some View {
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
                if joinAllowed {
                    Button(L10n.PhoneWizard.useAccount) {
                        useJoin = true
                        startWarmup()
                        startJoin()
                    }
                    .banditoButton(.link)
                    .font(BanditoFont.text(size: 12, weight: 400))
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
            if isJoinShown, let shownJoin {
                JoinQRButtons(model: shownJoin, close: { dismiss() })
            } else {
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
    }

    private struct ServerChoice: Identifiable {
        let id: UUID
        let name: String
    }

    private func startJoin() {
        joinTask?.cancel()
        joinTask = Task { await enterJoin() }
    }

    /// Makes the join code (once) and starts it. Called when the scan step is reached or the person picks it.
    private func enterJoin() async {
        guard joinAllowed, joinModel == nil, preview == nil else { return }
        let close = dismiss
        guard let made = try? await JoinQRFactory.make(hub: hub, onFinished: { close() }) else {
            // The keys cannot be read: the pairing path takes over, and the access turned on for the join stops.
            joinAllowed = false
            warmup?.cancel()
            startPairCode()
            return
        }
        // The person went back to the pairing code, or left, while the model was made: its ticket is taken back.
        guard let made = JoinQRFactory.adopt(made, gone: joinModel != nil || !useJoin || disappeared) else { return }
        joinModel = made
        made.start()
    }

    /// Back to the pairing code: the join ticket is cancelled, and the background access stops (the pairing path turns
    /// the cloud on for the server it picks).
    private func leaveJoin() {
        useJoin = false
        joinModel?.close()
        joinModel = nil
        let warming = warmup
        warmup?.cancel()
        // An access that is being turned on finishes first: the pairing path then finds the server on and registers
        // nothing a second time.
        Task { @MainActor in
            await warming?.settle()
            startPairCode()
        }
    }

    /// The first path: the join code now, the access on every server in the background.
    private func startJoinFirst() {
        if warmup == nil {
            let hub = hub
            let relays = relays
            warmup = PhoneAccessWarmup { server in
                let ready = await relays.enable(relays.controller(for: server, hub: hub))
                if ready { hub.requestAccessCycle() }
                return ready
            }
        }
        startWarmup()
        startJoin()
    }

    private func startWarmup() {
        warmup?.start(app.servers)
    }

    /// The pairing path: the server is picked (or taken when there is one), the cloud turned on, the code shown.
    private func startPairCode() {
        guard model == nil, !disappeared else { return }
        let hub = hub
        let relays = relays
        let made = ConnectPhoneModel(
            candidates: app.servers,
            makeController: { server in relays.controller(for: server, hub: hub) })
        model = made
        made.start()
    }

    private func begin() async {
        guard preview == nil, previewJoin == nil, model == nil, warmup == nil else { return }
        joinAllowed = await JoinQRFactory.blocker(of: hub) == nil
        joinChecked = true
        guard !disappeared else { return }
        switch PhoneWizardPath.path(accountReady: joinAllowed) {
        case .joinFirst:
            startJoinFirst()
        case .pairCode:
            startPairCode()
        }
    }
}

/// The cloud controllers of the wizard, one per server. A controller that is busy (the other path is turning the access
/// on) is waited for instead of asked again: `RelayController.enable` answers false while it is busy.
@MainActor
final class SharedRelayControllers {
    private var controllers: [UUID: RelayController] = [:]

    func controller(for server: any PhoneWizardServer, hub: AccountHub) -> RelayController {
        if let made = controllers[server.wizardID] { return made }
        let made = RelayController(
            host: server,
            registrar: { [hub] in
                guard await hub.signedIn else { return nil }
                return try await hub.prepare()
            })
        controllers[server.wizardID] = made
        return made
    }

    /// Turns the access on, or waits for the run already under way and reads its outcome.
    func enable(_ controller: RelayController) async -> Bool {
        guard controller.isBusy else { return await controller.enable() }
        while controller.isBusy {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return controller.isConnected
    }
}
