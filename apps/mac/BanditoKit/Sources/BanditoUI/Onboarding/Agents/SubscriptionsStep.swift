import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The subscriptions of the server's agent CLIs: install a missing one, and the login of each one in a terminal on the server.
/// State comes from `runtimes.status` (polled every three seconds while the step is open), `usage.limits` (plan) and
/// `setup.status` (what is installed and what Bandito can install here).
@MainActor
@Observable
final class SubscriptionsModel {
    static let kinds: [RuntimeKind] = [.claude, .codex, .grok]

    let server: ServerModel
    /// The setup status of the server and the install jobs of the agent CLIs (`setup.*`).
    let setup = SetupModel()
    /// The runtime whose login terminal is open, if any.
    private(set) var loginRuntime: RuntimeKind?
    /// Set before the terminal is requested, so a second tap cannot open a second terminal.
    @ObservationIgnored private var gate = LoginGate()
    /// Cancels the logins that are still opening when the person leaves the step.
    @ObservationIgnored private var loginEpoch = LoginEpoch()
    /// Whether a login is being opened right now (buttons are disabled meanwhile).
    var isOpening: Bool { gate.isOpening }
    private(set) var terminal: TerminalSession?
    /// The last https link the login printed. Only https is ever offered.
    private(set) var latestLink: URL?
    private(set) var errorText: UserFacingMessage?
    /// The runtime whose login could not be opened: "Try again" opens it again.
    private(set) var failedLogin: RuntimeKind?
    /// Runtimes the person confirmed with "Done", for the ones the server cannot verify.
    private(set) var confirmed: Set<RuntimeKind> = []
    /// The runtime whose install is running, if any. One install at a time.
    private(set) var installing: RuntimeKind?
    /// The runtime the last install was started for: its "Try again" and its command to install by hand.
    private(set) var lastInstall: RuntimeKind?
    /// Why the runtimes could not be read. "Try again" reads them again.
    private(set) var statusError: UserFacingMessage?

    @ObservationIgnored private var outputTail = ""

    init(server: ServerModel) {
        self.server = server
    }

    func state(_ kind: RuntimeKind) -> SubscriptionState? {
        guard let status = server.runtimes.first(where: { $0.kind == kind }) else { return nil }
        let plan = server.usage.first { $0.runtime == kind.rawValue }?.plan?.label
        return SubscriptionState.resolve(
            installed: status.installed, loggedIn: status.loggedIn, plan: plan, confirmed: confirmed.contains(kind))
    }

    /// The setup component of an agent CLI, when the setup status is known and has it.
    func component(_ kind: RuntimeKind) -> SetupComponent? {
        setup.status?.components.first { $0.id == kind.rawValue }
    }

    /// What the row of `kind` offers. A CLI missing from a known setup status is one Bandito cannot install here.
    func rowAction(_ kind: RuntimeKind) -> SubscriptionRowAction {
        let installable: Bool? = setup.status == nil ? nil : (component(kind)?.installable ?? false)
        return SubscriptionRowAction.resolve(state: state(kind), installable: installable, installing: installing == kind)
    }

    /// The runtimes that can create an agent now.
    var signedIn: [RuntimeKind] {
        Self.kinds.filter { state($0)?.isReady == true }
    }

    /// One poll: fresh runtime states, and the login is closed as soon as its runtime reports signed in.
    func poll() async {
        await refreshRuntimes()
        // A server that says "not signed in" overrides an earlier "Done".
        for kind in Self.kinds where server.runtimes.first(where: { $0.kind == kind })?.loggedIn == false {
            confirmed.remove(kind)
        }
        if let kind = loginRuntime, state(kind)?.isReady == true {
            await endLogin()
        }
    }

    /// "Check again" and "Try again": the runtimes and the setup status are read again.
    func checkAgain() async {
        await refreshRuntimes()
        await setup.load(server)
    }

    private func refreshRuntimes() async {
        do {
            try await server.refreshRuntimes()
            statusError = nil
        } catch {
            statusError = SignInMessages.text(for: error)
        }
    }

    /// Installs one agent CLI on the server (`setup.install` for that one component), then reads the states again.
    func install(_ kind: RuntimeKind) async {
        guard installing == nil, !setup.isRunning else { return }
        installing = kind
        lastInstall = kind
        defer { installing = nil }
        await setup.install([kind.rawValue], server: server)
        await refreshRuntimes()
    }

    /// Starts the login command of `kind` in a terminal on the server and follows its output.
    func startLogin(_ kind: RuntimeKind) async {
        guard terminal == nil, gate.tryStart() else { return }
        defer { gate.finish() }
        errorText = nil
        failedLogin = nil
        latestLink = nil
        outputTail = ""
        let ticket = loginEpoch.ticket
        do {
            let info = try await server.openTerminal(
                command: LoginCommand.arguments(for: kind), title: L10n.Onboarding.Subs.loginTitle(name: title(kind)),
                cols: 100, rows: 28)
            // The person left the step while the terminal was opening: the terminal is closed, not shown.
            guard loginEpoch.isCurrent(ticket) else {
                try? await server.closeTerminal(info.id)
                return
            }
            let session = TerminalSession(info: info, server: server, fontSize: 13)
            session.onOutput = { [weak self] data in
                Task { @MainActor in self?.consume(data) }
            }
            session.onClosed = { [weak self] in
                Task { @MainActor in
                    self?.terminal = nil
                    self?.loginRuntime = nil
                }
            }
            terminal = session
            loginRuntime = kind
            await session.attach()
        } catch {
            errorText = SignInMessages.text(for: error)
            failedLogin = kind
        }
    }

    /// "Done" for a runtime the server cannot verify (Grok reports no login): the person says it is signed in.
    func confirm(_ kind: RuntimeKind) async {
        confirmed.insert(kind)
        if loginRuntime == kind {
            await endLogin()
        }
    }

    /// Closes the login terminal on the server and stops following it.
    func endLogin() async {
        loginEpoch.cancel()
        guard let session = terminal else { return }
        terminal = nil
        loginRuntime = nil
        session.stop()
        try? await server.closeTerminal(session.id)
    }

    private func consume(_ data: Data) {
        outputTail += String(decoding: data, as: UTF8.self)
        if outputTail.count > 16_384 {
            outputTail = String(outputTail.suffix(8_192))
        }
        if let link = LoginLink.lastHTTPS(in: outputTail) {
            latestLink = link
        }
    }

    func title(_ kind: RuntimeKind) -> String {
        switch kind {
        case .claude: L10n.Runtime.claude
        case .codex: L10n.Runtime.codex
        case .grok: L10n.Runtime.grok
        case .api: kind.rawValue
        }
    }

    func hint(_ kind: RuntimeKind) -> String {
        switch kind {
        case .claude: L10n.Onboarding.Subs.hintClaude
        case .codex: L10n.Onboarding.Subs.hintCodex
        case .grok: L10n.Onboarding.Subs.hintGrok
        case .api: ""
        }
    }
}

/// Step 4 of 5, part one: the agent subscriptions of the server.
struct SubscriptionsStep: View {
    var model: SubscriptionsModel
    /// Goes on to the first agent, with or without a subscription (the next step explains what is needed).
    var onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Onboarding.Subs.title)
                .font(BanditoFont.display(size: 35, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Onboarding.Subs.subtitle)
                .font(BanditoFont.text(size: 15, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            VStack(spacing: 10) {
                ForEach(SubscriptionsModel.kinds, id: \.self) { kind in
                    row(kind)
                }
            }
            if model.loginRuntime != nil {
                loginPanel
            }
            installProblem
            if let statusError = model.statusError ?? model.setup.error {
                HStack(spacing: 10) {
                    UserFacingErrorView(message: statusError)
                    Button(L10n.Onboarding.Server.retry) { Task { await model.checkAgain() } }
                        .banditoButton(.quiet(size: .regular))
                }
            }
            if let errorText = model.errorText {
                HStack(spacing: 10) {
                    UserFacingErrorView(message: errorText)
                    if let kind = model.failedLogin {
                        Button(L10n.Onboarding.Server.retry) { Task { await model.startLogin(kind) } }
                            .banditoButton(.quiet(size: .regular))
                    }
                }
            }
            Text(L10n.Onboarding.Subs.needOne)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
        }
        .frame(maxWidth: 760, alignment: .topLeading)
        // "Next" of this step is in the flow's bottom bar, at the same place as on the other steps.
        .onboardingNext(OnboardingNextAction(title: L10n.Onboarding.Subs.continueLabel, isEnabled: true, perform: onContinue))
        .task { await model.checkAgain() }
    }

    private func row(_ kind: RuntimeKind) -> some View {
        let action = model.rowAction(kind)
        return HStack(spacing: 14) {
            RaccoonAvatar(name: model.title(kind), size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title(kind))
                    .font(BanditoFont.text(size: 15, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                statusLine(kind, action)
            }
            Spacer()
            actions(kind, action)
        }
        .padding(14)
        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.text.opacity(0.08)))
    }

    /// One status per row. A CLI Bandito cannot install shows the daemon's hint (a link or a reason) under it.
    private func statusLine(_ kind: RuntimeKind, _ action: SubscriptionRowAction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(statusText(action))
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(action == .ready ? AvatarColor.sage.color : Color.Bandito.text3)
            if action == .installing, let line = InstallLog.lastLine(model.setup.log) {
                Text(line)
                    .font(BanditoFont.mono(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if action == .installByHand, let hint = model.component(kind)?.hint {
                Text(hint)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func actions(_ kind: RuntimeKind, _ action: SubscriptionRowAction) -> some View {
        switch action {
        case .checking:
            ProgressView().controlSize(.small)
        case .install:
            Button(L10n.Setup.install) { Task { await model.install(kind) } }
                .banditoButton(.quiet(size: .regular))
                .disabled(model.installing != nil || model.setup.isRunning)
        case .installing:
            ProgressView().controlSize(.small)
        case .installByHand:
            Button(L10n.Onboarding.Server.checkAgain) { Task { await model.checkAgain() } }
                .banditoButton(.quiet(size: .regular))
        case .signIn:
            HStack(spacing: 8) {
                Button(L10n.Onboarding.Subs.signIn) { Task { await model.startLogin(kind) } }
                    .banditoButton(.signal(size: .regular))
                    .disabled(model.terminal != nil)
                Button(L10n.Onboarding.Server.checkAgain) { Task { await model.checkAgain() } }
                    .banditoButton(.quiet(size: .regular))
            }
        case .confirm:
            HStack(spacing: 8) {
                Button(L10n.Onboarding.Subs.signIn) { Task { await model.startLogin(kind) } }
                    .banditoButton(.quiet(size: .regular))
                    .disabled(model.terminal != nil)
                Button(L10n.Onboarding.Subs.done) { Task { await model.confirm(kind) } }
                    .banditoButton(.signal(size: .regular))
            }
        case .ready:
            HStack(spacing: 8) {
                if let plan = model.state(kind).flatMap(Self.plan) {
                    Text(plan)
                        .font(BanditoFont.text(size: 12, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.Bandito.text.opacity(0.06), in: Capsule())
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AvatarColor.sage.color)
            }
        }
    }

    private static func plan(_ state: SubscriptionState) -> String? {
        if case .loggedIn(let plan) = state { return plan }
        return nil
    }

    /// What the install of the last CLI needs from the person: the sudo command to run on the server, or the
    /// reason it failed with the command to install by hand. Nil while nothing failed.
    @ViewBuilder
    private var installProblem: some View {
        if model.installing == nil, let job = model.setup.job {
            switch job.state {
            case .needsPassword:
                permissionBlock(command: job.command)
            case .failed:
                if let kind = model.lastInstall {
                    if InstallPermission.isPermissionProblem(model.setup.log) {
                        permissionBlock(command: ManualInstall.command(for: kind))
                    } else {
                        failedBlock(kind)
                    }
                }
            case .running, .done:
                EmptyView()
            }
        }
    }

    private func permissionBlock(command: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Onboarding.Server.passwordHint)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            if let command {
                HStack(spacing: 10) {
                    Text(command)
                        .font(BanditoFont.mono(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Button { SystemActions.copy(command) } label: { Text(L10n.Onboarding.Server.copy).lineLimit(1) }
                        .banditoButton(.quiet(size: .regular))
                }
            }
            Button(L10n.Onboarding.Server.doneCheckAgain) { Task { await model.checkAgain() } }
                .banditoButton(.signal(size: .regular))
        }
        .padding(16)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 16))
    }

    private func failedBlock(_ kind: RuntimeKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Onboarding.Subs.installFailed(name: model.title(kind)))
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.danger)
            if let line = InstallLog.lastLine(model.setup.log) {
                Text(line)
                    .font(BanditoFont.mono(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(2)
            }
            Button(L10n.Onboarding.Server.retry) { Task { await model.install(kind) } }
                .banditoButton(.signal(size: .regular))
        }
        .padding(16)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 16))
    }

    private var loginPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let kind = model.loginRuntime {
                HStack(spacing: 10) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                        PulseDot(t: context.date.timeIntervalSinceReferenceDate, color: Color.Bandito.signal)
                    }
                    Text(model.hint(kind))
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineSpacing(2)
                }
                Text(L10n.Onboarding.Subs.loginAfter)
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
            }
            if let session = model.terminal {
                TerminalPane(view: session.view, fontSize: 13)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 10) {
                if let link = model.latestLink {
                    Button(L10n.Onboarding.Subs.openLink) { SystemActions.open(link) }
                        .banditoButton(.quiet(size: .regular))
                    Text(L10n.Onboarding.Subs.linkHost(host: link.host ?? ""))
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
                Spacer()
                Button(L10n.Onboarding.Server.checkAgain) { Task { await model.checkAgain() } }
                    .banditoButton(.quiet(size: .regular))
                Button(L10n.Onboarding.Server.back) { Task { await model.endLogin() } }
                    .buttonStyle(.plain)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .padding(16)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statusText(_ action: SubscriptionRowAction) -> String {
        switch action {
        case .checking: L10n.Onboarding.Subs.stateChecking
        case .install, .installByHand: L10n.Onboarding.Subs.stateNotInstalled
        case .installing: L10n.Onboarding.Subs.installing
        case .signIn: L10n.Onboarding.Subs.stateNeedsLogin
        case .confirm: L10n.Onboarding.Subs.stateUnverified
        case .ready: L10n.Onboarding.Subs.stateSignedIn
        }
    }
}
