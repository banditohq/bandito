import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The subscriptions of the server's agent CLIs, and the login of each one in a terminal on the server.
/// State comes from `runtimes.status` (polled every three seconds while the step is open) and `usage.limits` (plan).
@MainActor
@Observable
final class SubscriptionsModel {
    static let kinds: [RuntimeKind] = [.claude, .codex, .grok]

    let server: ServerModel
    /// The runtime whose login terminal is open, if any.
    private(set) var loginRuntime: RuntimeKind?
    /// Set before the terminal is requested, so a second tap cannot open a second terminal.
    @ObservationIgnored private var gate = LoginGate()
    /// Whether a login is being opened right now (buttons are disabled meanwhile).
    var isOpening: Bool { gate.isOpening }
    private(set) var terminal: TerminalSession?
    /// The last https link the login printed. Only https is ever offered.
    private(set) var latestLink: URL?
    private(set) var errorText: String?
    /// Runtimes the person confirmed with "Done", for the ones the server cannot verify.
    private(set) var confirmed: Set<RuntimeKind> = []

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

    /// The runtimes that can create an agent now.
    var signedIn: [RuntimeKind] {
        Self.kinds.filter { state($0)?.isReady == true }
    }

    /// One poll: fresh runtime states, and the login is closed as soon as its runtime reports signed in.
    func poll() async {
        try? await server.refreshRuntimes()
        // A server that says "not signed in" overrides an earlier "Done".
        for kind in Self.kinds where server.runtimes.first(where: { $0.kind == kind })?.loggedIn == false {
            confirmed.remove(kind)
        }
        if let kind = loginRuntime, state(kind)?.isReady == true {
            await endLogin()
        }
    }

    /// Starts the login command of `kind` in a terminal on the server and follows its output.
    func startLogin(_ kind: RuntimeKind) async {
        guard terminal == nil, gate.tryStart() else { return }
        defer { gate.finish() }
        errorText = nil
        latestLink = nil
        outputTail = ""
        do {
            let info = try await server.openTerminal(
                command: LoginCommand.arguments(for: kind), title: L10n.Onboarding.Subs.loginTitle(name: title(kind)),
                cols: 100, rows: 28)
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
                .font(BanditoFont.font(size: 38, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Onboarding.Subs.subtitle)
                .font(BanditoFont.font(size: 15, weight: 400))
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
            if let errorText = model.errorText {
                Text(errorText)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            Text(L10n.Onboarding.Subs.needOne)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
        }
        .frame(maxWidth: 760, alignment: .topLeading)
        // "Next" of this step is in the flow's bottom bar, at the same place as on the other steps.
        .onboardingNext(OnboardingNextAction(title: L10n.Onboarding.Subs.continueLabel, isEnabled: true, perform: onContinue))
    }

    private func row(_ kind: RuntimeKind) -> some View {
        let state = model.state(kind)
        return HStack(spacing: 14) {
            RaccoonAvatar(name: model.title(kind), size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title(kind))
                    .font(BanditoFont.font(size: 15, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                Text(stateText(state))
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(stateColor(state))
            }
            Spacer()
            actions(kind, state)
        }
        .padding(14)
        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.text.opacity(0.08)))
    }

    @ViewBuilder
    private func actions(_ kind: RuntimeKind, _ state: SubscriptionState?) -> some View {
        switch state {
        case .needsLogin:
            Button(L10n.Onboarding.Subs.signIn) { Task { await model.startLogin(kind) } }
                .buttonStyle(SignalButtonStyle(size: .regular))
                .disabled(model.terminal != nil)
        case .unverified:
            HStack(spacing: 8) {
                Button(L10n.Onboarding.Subs.signIn) { Task { await model.startLogin(kind) } }
                    .buttonStyle(QuietButtonStyle(size: .regular))
                    .disabled(model.terminal != nil)
                Button(L10n.Onboarding.Subs.done) { Task { await model.confirm(kind) } }
                    .buttonStyle(SignalButtonStyle(size: .regular))
            }
        case .loggedIn(let plan):
            HStack(spacing: 8) {
                if let plan {
                    Text(plan)
                        .font(BanditoFont.font(size: 12, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.Bandito.text.opacity(0.06), in: Capsule())
                }
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AvatarColor.sage.color)
            }
        case .notInstalled:
            Text(L10n.Onboarding.Subs.notInstalled)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private var loginPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let kind = model.loginRuntime {
                HStack(spacing: 10) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                        PulseDot(t: context.date.timeIntervalSinceReferenceDate, color: Color.Bandito.signal)
                    }
                    Text(model.hint(kind))
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineSpacing(2)
                }
            }
            if let session = model.terminal {
                TerminalPane(view: session.view, fontSize: 13)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 10) {
                if let link = model.latestLink {
                    Button(L10n.Onboarding.Subs.openLink) { SystemActions.open(link) }
                        .buttonStyle(QuietButtonStyle(size: .regular))
                    Text(L10n.Onboarding.Subs.linkHost(host: link.host ?? ""))
                        .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text3)
                }
                Spacer()
                Button(L10n.Onboarding.Subs.skipLater) { onContinue() }
                    .buttonStyle(.plain)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .padding(16)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 16))
    }

    private func stateText(_ state: SubscriptionState?) -> String {
        switch state {
        case .notInstalled: L10n.Onboarding.Subs.stateNotInstalled
        case .needsLogin: L10n.Onboarding.Subs.stateNeedsLogin
        case .unverified: L10n.Onboarding.Subs.stateUnverified
        case .loggedIn: L10n.Onboarding.Subs.stateSignedIn
        case nil: L10n.Onboarding.Subs.stateChecking
        }
    }

    private func stateColor(_ state: SubscriptionState?) -> Color {
        state?.isReady == true ? AvatarColor.sage.color : Color.Bandito.text3
    }
}
