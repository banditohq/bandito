import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The sign-in inside the profile card, for someone who is not signed in: GitHub, or an e-mail code. It uses the
/// onboarding's models (`AccountModels`, `EmailSignInModel`, `GitHubSignInModel`) and shows them compactly.
struct ProfileSignInBlock: View {
    /// Signed in with GitHub or by e-mail: the card goes on with the account.
    var onSignedIn: () -> Void

    @Environment(AccountHub.self) private var hub
    @State private var models: AccountModels?
    @State private var setupError: UserFacingMessage?
    @State private var emailOpen = false
    @State private var copiedNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Account.SignIn.title)
                .font(BanditoFont.font(size: 20, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Account.SignIn.text)
                .font(BanditoFont.font(size: 13.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let setupError {
                UserFacingErrorView(message: setupError)
            }
            if let github = models?.github {
                githubBlock(github)
            }
            if emailOpen, let models {
                ProfileEmailFields(model: models.email)
            } else {
                Button(L10n.Account.SignIn.byEmail) { emailOpen = true }
                    .banditoButton(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await build() }
        .onChange(of: finishedSession) { _, session in
            if session != nil { onSignedIn() }
        }
        // Leaving the card stops a GitHub wait that is still running.
        .onDisappear { models?.github.cancel() }
    }

    /// The GitHub flow in the card itself, with no second sheet: the button, then the code while it is waited for.
    @ViewBuilder
    private func githubBlock(_ github: GitHubSignInModel) -> some View {
        switch github.state {
        case .idle, .signedIn:
            Button {
                copiedNote = false
                github.start()
            } label: {
                HStack(spacing: 8) {
                    GitHubMark()
                        .fill(Color.Bandito.bg)
                        .frame(width: 16, height: 16)
                    Text(L10n.Onboarding.Account.continueGithub)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
            }
            .banditoButton(.lightPill())
        case .connecting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.Onboarding.Account.Github.connecting)
                    .foregroundStyle(Color.Bandito.text2)
            }
        case .waiting(let flow):
            VStack(alignment: .leading, spacing: 12) {
                Text(UserCodeFormat.grouped(flow.userCode))
                    .font(BanditoFont.font(size: 28, weight: 600, mono: true))
                    .foregroundStyle(Color.Bandito.text)
                    .tracking(3)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Button(L10n.Onboarding.Account.Github.copyAndOpen) {
                        github.copyAndOpen()
                        copiedNote = true
                    }
                    .banditoButton(.signal())
                    .fixedSize()
                    Button(L10n.Common.cancel) { github.cancel() }
                        .banditoButton(.quiet())
                        .fixedSize()
                }
                if copiedNote {
                    Text(L10n.Onboarding.Account.Github.copied)
                        .font(BanditoFont.font(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.Onboarding.Account.Github.waiting)
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
        case .expired:
            githubFailure(UserFacingMessage(text: L10n.Onboarding.Account.Github.expired), github)
        case .denied:
            githubFailure(UserFacingMessage(text: L10n.Onboarding.Account.Github.denied), github)
        case .failed(let message):
            githubFailure(message, github)
        }
    }

    private func githubFailure(_ message: UserFacingMessage, _ github: GitHubSignInModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            UserFacingErrorView(message: message)
            Button(L10n.Onboarding.Account.Github.retry) {
                copiedNote = false
                github.start()
            }
            .banditoButton(.signal())
            .fixedSize()
        }
    }

    /// Set when either way of signing in succeeded.
    private var finishedSession: Session? {
        if let session = models?.email.signedIn { return session }
        if case .signedIn(let session)? = models?.github.state { return session }
        return nil
    }

    private func build() async {
        guard models == nil else { return }
        do {
            models = AccountModels(service: try await hub.prepare())
        } catch {
            setupError = SignInMessages.setupText(for: error)
        }
    }
}

/// The e-mail branch in compact form: the address, then one field for the six digits. A complete code is checked.
private struct ProfileEmailFields: View {
    @Bindable var model: EmailSignInModel
    @State private var codeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.phase == .address {
                HStack(spacing: 8) {
                    TextField(L10n.Onboarding.Account.emailPlaceholder, text: $model.email)
                        .banditoField()
                        .font(BanditoFont.font(size: 14, weight: 400))
                        .onSubmit { send() }
                        .accessibilityLabel(L10n.Onboarding.Account.emailLabel)
                    Button(L10n.Onboarding.Account.sendCode) { send() }
                        .banditoButton(.signal())
                        .fixedSize()
                        .disabled(model.isBusy)
                }
            } else {
                Text(L10n.Onboarding.Account.codeHint(email: model.email))
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("000000", text: $codeText)
                    .banditoField()
                    .font(BanditoFont.font(size: 20, weight: 600, mono: true))
                    .frame(width: 180)
                    .accessibilityLabel(L10n.Onboarding.Account.emailLabel)
                    .onChange(of: codeText) { _, text in
                        let digits = String(text.filter { $0.isASCII && $0.isNumber }.prefix(SixDigitCode.length))
                        if digits != text {
                            codeText = digits
                        }
                        if digits.count == SixDigitCode.length {
                            Task { await model.enter(digits, at: 0) }
                        }
                    }
                    .onChange(of: model.code.value) { _, value in
                        // A wrong code clears the model's boxes; the field follows.
                        if value.isEmpty { codeText = "" }
                    }
                HStack(spacing: 14) {
                    resend
                    Button(L10n.Onboarding.Account.changeEmail) { model.changeEmail() }
                        .banditoButton(.link)
                }
                if model.isBusy {
                    Text(L10n.Onboarding.Account.checking)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            if let error = model.errorText {
                UserFacingErrorView(message: error)
            }
        }
    }

    private func send() {
        Task { await model.sendCode(now: Date()) }
    }

    /// "Send a new code", with the seconds left while the server's wait runs.
    private var resend: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = model.cooldown.remaining(now: context.date)
            Button(left > 0 ? L10n.Onboarding.Account.resendIn(seconds: String(left)) : L10n.Onboarding.Account.resend) {
                Task { await model.resend(now: Date()) }
            }
            .banditoButton(.link)
            .disabled(left > 0 || model.isBusy)
        }
    }
}
