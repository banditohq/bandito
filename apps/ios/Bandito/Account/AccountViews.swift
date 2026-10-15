import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

/// The account screen: sign in (GitHub or an email code), wait for the approval on a Mac, then the servers of the account
/// and sign-out. One page whose body follows `IOSAccount.stage`. It is pushed in Settings and shown in a sheet from the
/// onboarding (`onClose` adds the Close button).
struct AccountScreen: View {
    @Bindable var account: IOSAccount
    var onClose: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var emailOpen = false
    @State private var copied = false
    @State private var confirmingSignOut = false
    /// The scanner for "Sign in with a Mac".
    @State private var scan: JoinScanRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BanditoSpace.s5) {
                content
                if let text = account.errorText {
                    AccountErrorBlock(text: text, details: account.errorDetails)
                        .accessibilityIdentifier("account.error")
                }
            }
            .padding(.horizontal, BanditoSpace.s5)
            .padding(.vertical, BanditoSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .navigationTitle(L10n.Account.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.close, action: onClose).accessibilityIdentifier("account.close")
                }
            }
        }
        .confirmationDialog(
            L10n.Ios.Account.SignOut.title, isPresented: $confirmingSignOut, titleVisibility: .visible
        ) {
            Button(L10n.Account.SignOut.confirm, role: .destructive) { Task { await account.signOut() } }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Ios.Account.SignOut.message)
        }
        .sheet(item: $scan) { _ in
            JoinScannerSheet(
                onTicket: { ticket in
                    scan = nil
                    Task { await account.join(ticket) }
                },
                onClose: { scan = nil })
                .preferredColorScheme(.dark)
        }
        .task { await account.start() }
    }

    @ViewBuilder private var content: some View {
        switch account.stage {
        case .signedOut: signIn
        case .loading:
            if account.joinMacName != nil { joinWaiting } else { loading }
        case .waitingForApproval(let code):
            if account.joinProblem == .foreign {
                foreignKey
            } else if account.joinMacName != nil {
                joinWaiting
            } else {
                waiting(code: code)
            }
        case .confirmSender(let code): confirm(code: code)
        case .rejected: rejected
        case .recoverRequired: recover
        case .ready: ready
        }
    }

    // MARK: Sign-in

    @ViewBuilder private var signIn: some View {
        title(L10n.Account.SignIn.title)
        paragraph(L10n.Ios.Account.SignIn.text)
        // The way that needs nothing typed comes first: the Mac shows a code, the camera reads it.
        VStack(spacing: BanditoSpace.s2) {
            Button {
                scan = JoinScanRequest()
            } label: {
                Text(L10n.Ios.Join.button).frame(maxWidth: .infinity)
            }
            .buttonStyle(SignalButtonStyle())
            .accessibilityIdentifier("account.join")
            Text(L10n.Ios.Join.buttonHint)
                .font(BanditoFont.text(size: 12))
                .foregroundStyle(Color.Bandito.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(L10n.Ios.Join.other)
            .font(BanditoFont.text(size: 13, weight: 500))
            .foregroundStyle(Color.Bandito.text3)
            .padding(.top, BanditoSpace.s2)
        if let github = account.github {
            githubBlock(github)
        } else {
            Button {
                Task { await account.startGitHub() }
            } label: {
                Text(L10n.Onboarding.Account.continueGithub).frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityIdentifier("account.github")
        }
        if emailOpen {
            emailBlock
        } else {
            Button(L10n.Account.SignIn.byEmail) {
                emailOpen = true
                Task { _ = try? await account.prepare() }
            }
            .buttonStyle(OnboardingLinkStyle())
            .accessibilityIdentifier("account.email.toggle")
        }
    }

    @ViewBuilder private func githubBlock(_ github: PhoneGitHubSignIn) -> some View {
        switch github.state {
        case .idle, .signedIn:
            Button {
                copied = false
                Task { await account.startGitHub() }
            } label: {
                Text(L10n.Onboarding.Account.continueGithub).frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityIdentifier("account.github")
        case .connecting:
            progress(L10n.Onboarding.Account.Github.connecting)
        case .waiting(let flow):
            card {
                Text(UserCodeFormat.grouped(flow.userCode))
                    .font(BanditoFont.mono(size: 30, weight: 600))
                    .tracking(3)
                    .foregroundStyle(Color.Bandito.text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("account.github.code")
                Button {
                    UIPasteboard.general.string = flow.userCode
                    copied = true
                    openURL(GitHubDevicePage.url)
                } label: {
                    Text(L10n.Onboarding.Account.Github.copyAndOpen).frame(maxWidth: .infinity)
                }
                .buttonStyle(SignalButtonStyle())
                if copied { footnote(L10n.Onboarding.Account.Github.copied) }
                progress(L10n.Onboarding.Account.Github.waiting)
                Button(L10n.Common.cancel) { account.cancelGitHub() }
                    .buttonStyle(OnboardingLinkStyle())
            }
        case .expired:
            githubFailure(L10n.Onboarding.Account.Github.expired)
        case .denied:
            githubFailure(L10n.Onboarding.Account.Github.denied)
        case .failed(let message):
            githubFailure(message)
        }
    }

    private func githubFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            Text(message)
                .font(BanditoFont.text(size: 13))
                .foregroundStyle(Color.Bandito.danger)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                copied = false
                Task { await account.startGitHub() }
            } label: {
                Text(L10n.Onboarding.Account.Github.retry).frame(maxWidth: .infinity)
            }
            .buttonStyle(SignalButtonStyle())
        }
    }

    @ViewBuilder private var emailBlock: some View {
        if let model = account.email {
            EmailFields(model: model, account: account)
        } else {
            progress(L10n.Onboarding.Account.Github.connecting)
        }
    }

    // MARK: Waiting for the Mac

    private var loading: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s4) {
            switch AccountLoadingPresentation.of(refreshing: account.refreshing > 0, hasError: account.errorText != nil) {
            case .checking:
                progress(L10n.Onboarding.Account.checking)
            case .retry:
                Button(L10n.Onboarding.Account.Github.retry) { Task { await account.start() } }
                    .buttonStyle(OnboardingLinkStyle())
            }
        }
    }

    /// Signed in by a Mac's code: the Mac is handing over the key. Nothing to do here but wait.
    @ViewBuilder private var joinWaiting: some View {
        let mac = account.joinMacName.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.Ios.Join.defaultMac
        title(L10n.Ios.Join.Waiting.title(mac: mac))
            .accessibilityIdentifier("account.join.waiting")
        paragraph(L10n.Ios.Join.Waiting.text)
        switch AccountLoadingPresentation.of(refreshing: account.refreshing > 0, hasError: account.errorText != nil) {
        case .checking:
            progress(L10n.Onboarding.Account.approvalWaiting)
        case .retry:
            Button(L10n.Onboarding.Account.Github.retry) { Task { await account.start() } }
                .buttonStyle(OnboardingLinkStyle())
        }
        signOutLink
    }

    /// A key came from somebody other than the Mac of the code. It was not taken.
    @ViewBuilder private var foreignKey: some View {
        title(L10n.Ios.Join.Foreign.title)
            .accessibilityIdentifier("account.join.foreign")
        paragraph(L10n.Ios.Join.Foreign.text)
        Button {
            account.compareManually()
        } label: {
            Text(L10n.Ios.Join.compare).frame(maxWidth: .infinity)
        }
        .buttonStyle(SignalButtonStyle())
        .accessibilityIdentifier("account.join.compare")
        signOutLink
    }

    @ViewBuilder private func waiting(code: String) -> some View {
        title(L10n.Ios.Account.Approval.title)
        if account.joinProblem == .silent {
            Text(L10n.Ios.Join.silent)
                .font(BanditoFont.text(size: 14))
                .foregroundStyle(Color.Bandito.danger)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.join.silent")
        }
        paragraph(L10n.Ios.Account.Approval.text)
        card {
            Text(L10n.Ios.Account.Approval.codeLabel)
                .font(BanditoFont.text(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            Text(code)
                .font(BanditoFont.mono(size: 26, weight: 600))
                .tracking(2)
                .foregroundStyle(Color.Bandito.text)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityIdentifier("account.ownCode")
        }
        progress(L10n.Onboarding.Account.approvalWaiting)
        signOutLink
    }

    @ViewBuilder private func confirm(code: String) -> some View {
        title(L10n.Ios.Account.Sender.title)
        card {
            Text(L10n.Ios.Account.Sender.codeLabel)
                .font(BanditoFont.text(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            Text(code)
                .font(BanditoFont.mono(size: 26, weight: 600))
                .tracking(2)
                .foregroundStyle(Color.Bandito.text)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .accessibilityIdentifier("account.senderCode")
        }
        paragraph(L10n.Onboarding.Account.senderHint)
        VStack(spacing: BanditoSpace.s3) {
            Button {
                Task { await account.confirmSender() }
            } label: {
                Text(L10n.Onboarding.Account.codesMatch).frame(maxWidth: .infinity)
            }
            .buttonStyle(SignalButtonStyle())
            .accessibilityIdentifier("account.codesMatch")
            Button {
                Task { await account.refuseSender() }
            } label: {
                Text(L10n.Onboarding.Account.codesDiffer).foregroundStyle(Color.Bandito.danger)
            }
            .buttonStyle(OnboardingLinkStyle())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("account.codesDiffer")
        }
    }

    @ViewBuilder private var rejected: some View {
        title(L10n.Onboarding.Account.refusedTitle)
        paragraph(L10n.Onboarding.Account.refusedText)
        Button {
            Task { await account.acknowledgeRejected() }
        } label: {
            Text(L10n.Onboarding.Account.understood).frame(maxWidth: .infinity)
        }
        .buttonStyle(SignalButtonStyle())
    }

    @ViewBuilder private var recover: some View {
        title(L10n.Onboarding.Account.recoverTitle)
        paragraph(L10n.Ios.Account.Recover.text)
        signOutLink
    }

    // MARK: Ready

    @ViewBuilder private var ready: some View {
        card {
            Text(L10n.Onboarding.Account.settingsSignedInAs(who: account.who))
                .font(BanditoFont.text(size: 14))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
                .accessibilityIdentifier("account.who")
        }
        Text(L10n.Ios.Account.Servers.header)
            .font(BanditoFont.display(size: 10.5, weight: 600))
            .tracking(0.6)
            .foregroundStyle(Color.Bandito.text3)
        if account.servers.isEmpty {
            paragraph(L10n.Ios.Account.Servers.empty)
        } else {
            card {
                ForEach(Array(account.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { Divider().overlay(Color.Bandito.line) }
                    ServerStateRow(server: server)
                }
            }
        }
        if account.hiddenCount > 0 {
            Button(L10n.Account.Hidden.show(count: account.hiddenCount)) { account.showHiddenServers() }
                .buttonStyle(OnboardingLinkStyle())
                .accessibilityIdentifier("account.hidden.show")
            footnote(L10n.Account.Hidden.hint)
        }
        footnote(L10n.Ios.Account.Servers.footer)
        signOutLink
    }

    private var signOutLink: some View {
        Button(L10n.Onboarding.Account.signOutAction) { confirmingSignOut = true }
            .buttonStyle(OnboardingLinkStyle())
            .accessibilityIdentifier("account.signOut")
    }

    // MARK: Pieces

    private func title(_ text: String) -> Text {
        Text(text).font(BanditoFont.display(size: 24, weight: 700)).foregroundColor(Color.Bandito.text)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 15))
            .foregroundStyle(Color.Bandito.text2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 12))
            .foregroundStyle(Color.Bandito.text3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: BanditoSpace.s3) {
            ProgressView()
            Text(text)
                .font(BanditoFont.text(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) { content() }
            .padding(BanditoSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.Bandito.surface1))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }
}

/// One server of the account and where this iPhone stands with it.
struct ServerStateRow: View {
    let server: AccessServerState

    var body: some View {
        HStack(spacing: BanditoSpace.s3) {
            Text(server.name)
                .font(BanditoFont.display(size: 13.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
            Spacer(minLength: BanditoSpace.s2)
            HStack(spacing: BanditoSpace.s2) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(label)
                    .font(BanditoFont.text(size: 12))
                    .foregroundStyle(Color.Bandito.text2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var dot: Color {
        switch server.status {
        case .connected: Color.Bandito.ok
        case .waitingForMac: Color.Bandito.signal
        case .noRemoteAccess, .hidden, .updateNeeded: Color.Bandito.text3
        }
    }

    private var label: String {
        switch server.status {
        case .connected: L10n.Ios.Account.Servers.connected
        case .waitingForMac: L10n.Ios.Account.Servers.waiting
        case .noRemoteAccess: L10n.Ios.Account.Servers.noAccess
        case .hidden: L10n.Ios.Account.Servers.hidden
        case .updateNeeded: L10n.Ios.Account.Servers.updateNeeded
        }
    }
}

/// The email fields: the address, then the six-digit code.
private struct EmailFields: View {
    @Bindable var model: PhoneEmailSignIn
    let account: IOSAccount
    @FocusState private var focused: Bool
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            switch model.phase {
            case .address:
                field(L10n.Onboarding.Account.emailPlaceholder, text: $model.email, contentType: .emailAddress, keyboard: .emailAddress)
                    .accessibilityIdentifier("account.email.field")
                    .onSubmit { Task { await account.sendEmailCode() } }
                Button {
                    Task { await account.sendEmailCode() }
                } label: {
                    Text(L10n.Onboarding.Account.sendCode).frame(maxWidth: .infinity)
                }
                .buttonStyle(SignalButtonStyle())
                .disabled(model.isBusy)
                .accessibilityIdentifier("account.email.send")
            case .code:
                Text(L10n.Onboarding.Account.codeHint(email: model.email))
                    .font(BanditoFont.text(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                field("000000", text: $model.code, contentType: .oneTimeCode, keyboard: .numberPad)
                    .font(BanditoFont.mono(size: 24, weight: 600))
                    .focused($focused)
                    .accessibilityIdentifier("account.email.code")
                    .onChange(of: model.code) { _, code in
                        if code.count == 6 { Task { await account.verifyEmailCode() } }
                    }
                if model.isBusy {
                    HStack(spacing: BanditoSpace.s3) {
                        ProgressView()
                        Text(L10n.Onboarding.Account.checking)
                            .font(BanditoFont.text(size: 13))
                            .foregroundStyle(Color.Bandito.text2)
                    }
                }
                HStack {
                    let remaining = model.cooldown.remaining(now: now)
                    Button(remaining == 0 ? L10n.Onboarding.Account.resend : L10n.Onboarding.Account.resendIn(seconds: String(remaining))) {
                        Task { await model.resend() }
                    }
                    .disabled(remaining > 0 || model.isBusy)
                    Spacer()
                    Button(L10n.Onboarding.Account.changeEmail) { model.changeEmail() }
                }
                .font(BanditoFont.text(size: 14, weight: 500))
                .buttonStyle(.plain)
                .foregroundStyle(Color.Bandito.text2)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        now = Date()
                    }
                }
            }
            if let text = model.errorText, !model.isBusy {
                AccountErrorBlock(text: text, details: model.errorDetails)
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, contentType: UITextContentType, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(BanditoFont.text(size: 16))
            .foregroundStyle(Color.Bandito.text)
            .padding(BanditoSpace.s4)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.Bandito.surface1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }
}

/// The GitHub user code as shown on screen: "WDJB-MJHT" stays as it is, eight plain characters get a hyphen in the middle.
enum UserCodeFormat {
    static func grouped(_ code: String) -> String {
        guard !code.contains("-"), code.count == 8 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 4)
        return String(code[..<middle]) + "-" + String(code[middle...])
    }
}

/// The Settings row that opens the account: signed out, a call to sign in; signed in, who and what is going on.
struct AccountSettingsRow: View {
    let account: IOSAccount

    var body: some View {
        HStack(spacing: BanditoSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BanditoFont.text(size: 15))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                Text(subtitle)
                    .font(BanditoFont.text(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        account.signedIn && !account.who.isEmpty
            ? L10n.Onboarding.Account.settingsSignedInAs(who: account.who) : L10n.Ios.Settings.Account.signIn
    }

    private var subtitle: String {
        switch account.stage {
        case .signedOut: L10n.Ios.Settings.Account.signInHint
        case .waitingForApproval, .confirmSender: L10n.Ios.Settings.Account.waiting
        case .ready: L10n.Ios.Settings.Account.ready
        case .loading, .rejected, .recoverRequired: L10n.Ios.Settings.Account.attention
        }
    }
}

/// What the loading page shows: a spinner while the account is being read, else the retry button. Never both: a
/// spinner next to an error that has already ended the attempt says the app is still working when it is not.
enum AccountLoadingPresentation: Equatable {
    case checking
    case retry

    static func of(refreshing: Bool, hasError: Bool) -> AccountLoadingPresentation {
        refreshing || !hasError ? .checking : .retry
    }
}

/// The message of a failure, and under it a small line with its technical code and a button that copies it, so a person
/// can send the reason.
struct AccountErrorBlock: View {
    let text: String
    var details: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s2) {
            Text(text)
                .font(BanditoFont.text(size: 13))
                .foregroundStyle(Color.Bandito.danger)
                .fixedSize(horizontal: false, vertical: true)
            if let details {
                HStack(spacing: BanditoSpace.s3) {
                    Text("\(L10n.Ios.Account.Error.details): \(details)")
                        .font(BanditoFont.mono(size: 11, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button(copied ? L10n.Ios.Account.Error.copied : L10n.Ios.Account.Error.copy) {
                        UIPasteboard.general.string = Self.report(details)
                        copied = true
                    }
                    .font(BanditoFont.text(size: 12, weight: 500))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.Bandito.text2)
                    .accessibilityIdentifier("account.error.copy")
                }
            }
        }
    }

    /// What is copied: the code, the app's version and the system's. Nothing about the person.
    static func report(_ details: String) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(details) | Bandito \(version) (\(build)) | iOS \(UIDevice.current.systemVersion)"
    }
}
