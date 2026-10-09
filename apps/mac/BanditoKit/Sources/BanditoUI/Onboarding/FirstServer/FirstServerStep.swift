import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Step 3 of 5 on screen: choose "This Mac" or "your server", watch the install, then see what the server has.
struct FirstServerStep: View {
    /// Goes on to the first agent (onboarding), or closes the add-server sheet.
    var onFinished: () -> Void
    /// Called once when the server is connected. The add-server sheet closes then.
    var onConnected: () -> Void = {}
    /// Onboarding: the "next" button of the connected state goes to the flow's bottom bar, at the fixed place.
    /// The add-server sheet keeps it inside the step.
    var placesNextInFooter = false

    @Environment(AppModel.self) private var app
    @Environment(AccountHub.self) private var hub
    @State private var model = FirstServerModel()
    @State private var showLog = false
    @State private var chooserWidth: CGFloat = 760

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch model.phase {
            case .choosing:
                chooser
            case .installing, .connecting:
                checklistView
            case .reviewingHost(let preview):
                hostReview(preview)
            case .failed:
                failureView
            case .connectFailed:
                connectFailedView
            case .connected(let config):
                connected(config)
            }
        }
        .frame(maxWidth: placesNextInFooter ? 760 : 620, alignment: .topLeading)
        .task {
            model.accountHub = hub
            await model.loadSuggestions()
        }
        .onChange(of: model.isConnected) { _, connected in
            if connected { onConnected() }
        }
    }

    // MARK: choosing

    /// The install command for a server, from the release. The install script checks the release signature itself.
    static let installCommand = "curl -fsSL https://github.com/banditohq/bandito/releases/latest/download/install.sh | sh"

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Onboarding.Server.title)
                    .font(BanditoFont.font(size: 38, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.Onboarding.Server.subtitle)
                    .font(BanditoFont.font(size: 15, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Side by side when the step is wide enough, compact rows one under another when it is not. In a row the
            // cards share the width equally and the tallest card sets the height.
            optionCards(side: chooserWidth >= Self.sideBySideWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { chooserWidth = $0 }
            if model.option == .ownServer {
                ownServerPanel
            }
        }
    }

    /// Width of the chooser below which the three cards become compact rows.
    static let sideBySideWidth: CGFloat = 620

    /// The three ways: this Mac, your own server, and "no server yet", which opens the guide and is not a choice.
    @ViewBuilder
    private func optionCards(side: Bool) -> some View {
        if side {
            HStack(alignment: .top, spacing: 14) {
                threeCards(side: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                threeCards(side: false)
            }
        }
    }

    @ViewBuilder
    private func threeCards(side: Bool) -> some View {
        Group {
            ServerOptionCard(
                title: L10n.Onboarding.Server.onThisMac, text: L10n.Onboarding.Server.thisMacDesc,
                icon: "laptopcomputer", tint: AvatarColor.sky.color,
                chip: L10n.Onboarding.Server.minutes(count: 1), link: nil, badge: nil,
                selected: model.option == .thisMac, dashed: false, side: side
            ) {
                model.startThisMac(app: app)
            }
            ServerOptionCard(
                title: L10n.Onboarding.Server.ownServer, text: L10n.Onboarding.Server.ownServerDesc,
                icon: "server.rack", tint: AvatarColor.sage.color,
                chip: L10n.Onboarding.Server.minutes(count: 3), link: nil, badge: L10n.Common.recommended,
                selected: model.option == .ownServer, dashed: false, side: side
            ) {
                model.choose(.ownServer)
            }
            ServerOptionCard(
                title: L10n.Onboarding.Server.noServer, text: L10n.Onboarding.Server.noServerDesc,
                icon: "questionmark.circle", tint: AvatarColor.lilac.color,
                chip: nil, link: L10n.Onboarding.Server.getServer, badge: nil,
                selected: false, dashed: true, side: side
            ) {
                SystemActions.open(URL(string: "https://bandito.dev/guide/server")!)
            }
        }
    }

    /// Under the own-server card: how to set it up, then the address and "Connect".
    private var ownServerPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SegmentedPicker(
                selection: $model.setupMode,
                options: [
                    (FirstServerModel.SetupMode.automatic, L10n.Onboarding.Server.modeAuto),
                    (FirstServerModel.SetupMode.command, L10n.Onboarding.Server.modeCommand),
                ])
            if model.setupMode == .command {
                commandSteps
            }
            addressBlock
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.surface1.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.Bandito.text.opacity(0.08)))
    }

    /// Step 1 of the command way: the install command on the server, with a copy button. The text scrolls sideways,
    /// so the command is never broken across lines.
    private var commandSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Onboarding.Server.commandStep1)
                .font(BanditoFont.font(size: 13.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            HStack(spacing: 10) {
                ScrollView(.horizontal) {
                    Text(Self.installCommand)
                        .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                CopyCommandButton(text: Self.installCommand)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.text.opacity(0.1)))
            Text(L10n.Onboarding.Server.commandHint)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Onboarding.Server.commandStep2)
                .font(BanditoFont.font(size: 13.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
        }
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.setupMode == .automatic {
                Text(L10n.Onboarding.Server.addressTitle)
                    .font(BanditoFont.font(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
            }
            HStack(spacing: 8) {
                TextField("user@host:22", text: $model.address)
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 14, weight: 400, mono: true))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.Bandito.text.opacity(0.12)))
                    .onSubmit { model.startOwnServer(app: app) }
                Button {
                    model.startOwnServer(app: app)
                } label: {
                    Text(L10n.Onboarding.Server.connect)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.signal())
            }
            if let addressError = model.addressError {
                Text(addressError)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.suggestions.isEmpty {
                suggestionChips
            }
            Text(model.setupMode == .command
                ? L10n.Onboarding.Server.commandConnectHint
                : L10n.Onboarding.Server.addressHint(path: "~/.ssh"))
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hosts from the person's ssh settings. Ten show as chips that wrap onto more rows; the rest sit in a menu.
    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Onboarding.Server.foundInConfig)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            FlowLayout(spacing: 6) {
                ForEach(model.suggestions.prefix(Self.visibleSuggestions), id: \.self) { host in
                    Button {
                        model.address = host
                    } label: {
                        Text(host)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .banditoButton(.quiet(size: .regular))
                }
                if model.suggestions.count > Self.visibleSuggestions {
                    Menu {
                        ForEach(model.suggestions.dropFirst(Self.visibleSuggestions), id: \.self) { host in
                            Button { model.address = host } label: { Text(host).oneLine() }
                        }
                    } label: {
                        Text(L10n.Onboarding.Server.moreHosts(count: model.suggestions.count - Self.visibleSuggestions))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .banditoButton(.quiet(size: .regular))
                }
            }
        }
    }

    /// How many ssh hosts are shown as chips before the "more" menu.
    static let visibleSuggestions = 10

    // MARK: installing

    private var checklistView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Onboarding.Server.installingTitle)
                .font(BanditoFont.font(size: 26, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            checklistRows
            journalPanel
        }
        .onAppear { showLog = false }
    }

    /// The lines of the checklist: a check for a finished line, a red cross for the one that failed, a ring for the rest.
    private var checklistRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.checklist.items.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    markView(model.checklist.mark(at: index))
                    Text(model.checklist.items[index].title)
                        .font(BanditoFont.font(size: 14.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                }
                .banditoAnimation(BanditoMotion.ease, value: model.checklist.mark(at: index))
            }
        }
    }

    /// The journal: every step and installer line with its time, the full error at the end. Folded away while the
    /// install runs; open when it failed. Scrolls to the newest line.
    private var journalPanel: some View {
        DisclosureGroup(isExpanded: $showLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.checklist.formattedLog.joined(separator: "\n"))
                            .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
                            .foregroundStyle(Color.Bandito.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("journal-end")
                    }
                    .padding(10)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 220)
                .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onAppear { proxy.scrollTo("journal-end", anchor: .bottom) }
                // The version counts every line, so it also moves when the journal is trimmed at its limit.
                .onChange(of: model.checklist.journalVersion) { _, _ in
                    proxy.scrollTo("journal-end", anchor: .bottom)
                }
            }
        } label: {
            Text(showLog ? L10n.Onboarding.Server.hideJournal : L10n.Onboarding.Server.showJournal)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
        }
        .font(BanditoFont.font(size: 12.5, weight: 500))
        .foregroundStyle(Color.Bandito.text2)
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
                Button {
                    Task { await model.trustHost(preview, app: app) }
                } label: {
                    Text(L10n.Onboarding.Server.trustHost).oneLine()
                }
                .banditoButton(.signal())
                Button { model.backToChoice() } label: { Text(L10n.Common.cancel).oneLine() }
                    .banditoButton(.quiet())
            }
        }
    }

    // MARK: failure

    /// The install stopped: the checklist stays, then the reason in plain words, what to do, the installer's own
    /// text when the reason does not say it, and the journal. Retry, back and copy the journal sit in one row.
    private var failureView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.Server.failedTitle)
                .font(BanditoFont.font(size: 24, weight: 600))
                .foregroundStyle(Color.Bandito.danger)
            checklistRows
            if let failure = model.failure {
                Text(Self.failureText(failure))
                    .font(BanditoFont.font(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let next = Self.nextStepText(InstallFailureAdvice.nextStep(for: failure)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Onboarding.Server.nextStepTitle)
                            .font(BanditoFont.font(size: 12.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text3)
                        Text(next)
                            .font(BanditoFont.font(size: 13.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if InstallFailureAdvice.showsDetails(failure), let detail = failure.errorDescription {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Onboarding.Server.detailsTitle)
                            .font(BanditoFont.font(size: 12.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text3)
                        Text(detail)
                            .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
                            .foregroundStyle(Color.Bandito.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                failureActions(failure)
            }
            if let hostKeyError = model.hostKeyError {
                UserFacingErrorView(message: hostKeyError)
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
                    CopyCommandButton(text: command)
                }
            }
            if let command = model.proxyCommand {
                HStack(spacing: 10) {
                    Text(command)
                        .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                    CopyCommandButton(text: command)
                }
            }
            if !model.checklist.journal.isEmpty {
                journalPanel
            }
            failureButtons
        }
        .onAppear { showLog = true }
    }

    /// Retry, back, and copy the journal, in one row. Retry is left out for a new host: its fingerprint review is the
    /// way on.
    private var failureButtons: some View {
        HStack(spacing: 10) {
            if model.failure != .sshFailed(.hostKeyUnknown) {
                Button {
                    retryInstall()
                } label: {
                    Text(L10n.Onboarding.Server.retry)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.signal())
            }
            Button {
                model.backToChoice()
            } label: {
                Text(L10n.Onboarding.Server.back)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .banditoButton(.quiet())
            Button {
                SystemActions.copy(model.checklist.formattedLog.joined(separator: "\n"))
            } label: {
                Text(L10n.Onboarding.Server.copyJournal)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .banditoButton(.quiet())
        }
    }

    /// Starts the same install again: the own server with its address, or this Mac.
    private func retryInstall() {
        if model.option == .ownServer {
            model.startOwnServer(app: app)
        } else {
            model.startThisMac(app: app)
        }
    }

    // MARK: connect failed

    /// The install finished, but the app did not connect within `FirstServerModel.connectTimeout`. The server stays
    /// added, so trying again only connects it.
    private var connectFailedView: some View {
        let text =
            model.option == .thisMac
            ? L10n.Onboarding.Server.Err.appNotConnectedThisMac
            : L10n.Onboarding.Server.Err.appNotConnectedServer
        return VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.Server.connectFailedTitle)
                .font(BanditoFont.font(size: 24, weight: 600))
                .foregroundStyle(Color.Bandito.danger)
            Text(text)
                .font(BanditoFont.font(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            HStack(spacing: 10) {
                Button { model.retryConnection(app: app) } label: { Text(L10n.Onboarding.Server.connectRetry).oneLine() }
                    .banditoButton(.signal())
                Button { model.backToChoice() } label: { Text(L10n.Onboarding.Server.back).oneLine() }
                    .banditoButton(.quiet())
            }
        }
    }

    /// The actions that belong to one reason: the fingerprint review for a new host, the key command for a rejected key.
    @ViewBuilder
    private func failureActions(_ failure: InstallError) -> some View {
        if case .sshFailed(.hostKeyUnknown) = failure {
            Button {
                Task { await model.reviewHost() }
            } label: {
                Text(L10n.Onboarding.Server.reviewHost)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .banditoButton(.signal())
        } else if case .sshFailed(.keyNotAccepted) = failure, let command = Self.copyKeyCommand(model.address) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Onboarding.Server.copyKeyHint)
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(command)
                        .font(BanditoFont.font(size: 13, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                    CopyCommandButton(text: command)
                }
            }
        }
    }

    /// The "what to do" line for a next step. Nil when the reason already says it.
    static func nextStepText(_ step: InstallNextStep) -> String? {
        switch step {
        case .checkTerminalLogin: return L10n.Onboarding.Server.Next.checkTerminalLogin
        case .checkServerAddress: return L10n.Onboarding.Server.Next.checkServerAddress
        case .checkServerReachable: return L10n.Onboarding.Server.Next.checkServerReachable
        case .checkSSHPort: return L10n.Onboarding.Server.Next.checkSSHPort
        case .checkGitHubAccess: return L10n.Onboarding.Server.Next.checkGitHubAccess
        case .retryLater: return L10n.Onboarding.Server.Next.retryLater
        case .checkSystemSupport(let uname): return L10n.Onboarding.Server.Next.checkSystemSupport(uname: uname)
        case .readLog: return L10n.Onboarding.Server.Next.readLog
        case .reviewFingerprint: return L10n.Onboarding.Server.Next.reviewFingerprint
        case .checkServerKey: return L10n.Onboarding.Server.Next.checkServerKey
        case .none: return nil
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
        case .releaseCheckFailed: return L10n.Onboarding.Server.Err.releaseCheck
        case .releaseStillPublishing(let tag): return L10n.Onboarding.Server.Err.releasePublishing(tag: tag)
        case .localBinaryMissing: return L10n.Onboarding.Server.Err.localBinary
        case .localDaemonNotStarted: return L10n.Onboarding.Server.Err.daemonNotStarted
        case .tokenNotSaved: return L10n.Onboarding.Server.Err.tokenNotSaved
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
                    UserFacingErrorView(message: syncError)
                    Button { model.syncServers(app: app) } label: { Text(L10n.Onboarding.Server.retry).oneLine() }
                        .banditoButton(.quiet(size: .regular))
                }
            }
            componentsBlock(config)
            if !placesNextInFooter {
                Button(action: onFinished) { Text(L10n.Onboarding.Server.nextAgent).oneLine() }
                    .banditoButton(.signal())
            }
        }
        .onboardingNext(placesNextInFooter
            ? OnboardingNextAction(title: L10n.Onboarding.Server.nextAgent, isEnabled: true, perform: onFinished)
            : nil)
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
                Button {
                    Task { await model.setup.install(model.setup.missingInstallable, server: server) }
                } label: {
                    Text(L10n.Onboarding.Server.installMissing).oneLine()
                }
                .banditoButton(.quiet())
            }
            if let server {
                Button {
                    Task { await model.setup.load(server) }
                } label: {
                    Text(L10n.Onboarding.Server.checkAgain).oneLine()
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
                Button { SystemActions.copy(command) } label: { Text(L10n.Onboarding.Server.copy).oneLine() }
                    .banditoButton(.quiet(size: .regular))
            }
            Button {
                Task { await model.setup.load(server) }
            } label: {
                Text(L10n.Onboarding.Server.doneCheckAgain).oneLine()
            }
            .banditoButton(.signal())
        }
    }
}

/// One way to run Bandito, as a whole-card button: a tinted tile, title, a line or two of text, and at the foot either a
/// time chip or a link. The chosen card has a signal border and a check. Hover lifts the card a little.
private struct ServerOptionCard: View {
    let title: String
    let text: String
    let icon: String
    let tint: Color
    /// The time it takes, e.g. "About 1 minute". Nil for a card without one.
    let chip: String?
    /// A link-like line at the foot, for the card that opens a guide.
    let link: String?
    /// The "recommended" label, set on the top row beside the title.
    let badge: String?
    let selected: Bool
    /// The dashed outline of the card that is not a choice.
    let dashed: Bool
    /// Side by side (equal fixed width) or stacked (full width).
    let side: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if side { column } else { row }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? Color.Bandito.signal.opacity(0.09) : Color.Bandito.text.opacity(hovered ? 0.05 : 0.025)))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.Bandito.onSignal)
                        .frame(width: 22, height: 22)
                        .background(Color.Bandito.signalFill, in: Circle())
                        .padding(12)
                }
            }
            .overlay(border)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(hovered ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .brandFocusRing(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovered = $0 }
        .banditoAnimation(BanditoMotion.ease, value: hovered)
        .banditoAnimation(BanditoMotion.ease, value: selected)
    }

    /// Side by side: tile, badge and title, text, and the chip at the foot. The row shares its width equally.
    private var column: some View {
        VStack(alignment: .leading, spacing: 12) {
            tile(size: 44)
            VStack(alignment: .leading, spacing: 6) {
                badgeView
                titleView
            }
            textView
            Spacer(minLength: 0)
            footer
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Stacked: one compact row — tile, title and text, the chip or link on the right.
    private var row: some View {
        HStack(alignment: .center, spacing: 14) {
            tile(size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    titleView
                    badgeView
                }
                textView
            }
            Spacer(minLength: 8)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .padding(.trailing, selected ? 26 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tile(size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(selected ? Color.Bandito.onSignal : tint)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: selected
                        ? [Color.Bandito.signalFill, Color.Bandito.signalFillEnd]
                        : [tint.opacity(0.28), tint.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }

    @ViewBuilder
    private var badgeView: some View {
        if let badge {
            Text(badge)
                .font(BanditoFont.font(size: 11, weight: 600))
                .foregroundStyle(AvatarColor.sage.color)
                .oneLine()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(AvatarColor.sage.color.opacity(0.14), in: Capsule())
        }
    }

    private var titleView: some View {
        Text(title)
            .font(BanditoFont.font(size: 16, weight: 600))
            .foregroundStyle(Color.Bandito.text)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var textView: some View {
        Text(text)
            .font(BanditoFont.font(size: 13.5, weight: 400))
            .foregroundStyle(Color.Bandito.text2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var footer: some View {
        if let chip {
            Text(chip)
                .font(BanditoFont.font(size: 12, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Color.Bandito.text.opacity(0.06), in: Capsule())
        } else if let link {
            Text(link)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.signal)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Group {
            if selected {
                shape.stroke(Color.Bandito.signal, lineWidth: 1.5)
            } else if dashed {
                shape.strokeBorder(
                    Color.Bandito.text.opacity(hovered ? 0.26 : 0.16),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            } else {
                shape.stroke(Color.Bandito.text.opacity(hovered ? 0.2 : 0.09), lineWidth: 1)
            }
        }
    }
}

/// "Copy" that says "Copied" for a moment after the press.
private struct CopyCommandButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            SystemActions.copy(text)
            copied = true
        } label: {
            Text(copied ? L10n.Onboarding.Server.copiedNote : L10n.Onboarding.Server.copy)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .banditoButton(.quiet(size: .regular))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            copied = false
        }
    }
}

/// The label of a button or chip: one line that never breaks inside a word or shrinks below its natural width.
private extension View {
    func oneLine() -> some View {
        lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}
