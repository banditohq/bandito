import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The two sign-in models, built once the account service is available.
@MainActor
@Observable
final class AccountModels {
    let github: GitHubSignInModel
    let email: EmailSignInModel

    init(service: SignInService) {
        github = GitHubSignInModel(service: service)
        email = EmailSignInModel(service: service)
    }
}

/// Step 2 of 5: sign in with GitHub or by email code, or go on without an account.
/// Signing in hands the session to the flow, which decides between approval and servers.
struct AccountSignInView: View {
    /// Signed in: the route this device takes next (see `AccountRoute`). The first device has its blob by now.
    var onFinished: (AccountRoute) -> Void
    /// "Continue without an account": everything stays on this Mac. Nil where there is no such choice (Settings).
    var onSkipAccount: (() -> Void)?
    /// The step's illustration on the left. Off in the Settings sheet, where there is no room for it.
    var showsIllustration = true

    @Environment(AccountHub.self) private var hub
    @State private var models: AccountModels?
    @State private var setupError: String?
    @State private var showGitHub = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if showsIllustration {
                    // Left column: about 44% of the step, the card keeps its inset from the flow's bars.
                    AccountIllustration()
                        .frame(width: Self.illustrationWidth(for: geometry.size.width))
                }
                // Right column: the form, vertically centered; it scrolls when the window is short.
                ScrollView {
                    form
                        .frame(maxWidth: 460, alignment: .leading)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                        .padding(.horizontal, showsIllustration ? 48 : 0)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task { await build() }
        .onChange(of: finishedSession) { _, session in
            if session != nil { Task { await finish() } }
        }
        .sheet(isPresented: $showGitHub) {
            if let github = models?.github {
                GitHubSignInSheet(model: github) {
                    showGitHub = false
                }
            }
        }
        // Leaving the screen stops a GitHub wait that is still running.
        .onDisappear { models?.github.cancel() }
    }

    /// The illustration column: 44% of the step's width, between 300 and 520 points.
    static func illustrationWidth(for stepWidth: CGFloat) -> CGFloat {
        min(520, max(300, (stepWidth * 0.44).rounded()))
    }

    /// Set when either way of signing in succeeded.
    private var finishedSession: Session? {
        if let session = models?.email.signedIn { return session }
        if case .signedIn(let session)? = models?.github.state { return session }
        return nil
    }

    /// Builds the models on the hub's client. The device key is read (or created once) by the app's identity store.
    private func build() async {
        guard models == nil else { return }
        do {
            models = AccountModels(service: try await hub.prepare())
        } catch {
            setupError = SignInMessages.setupText(for: error)
        }
    }

    /// A session is stored: the first device creates the sync blob, then the caller decides the next step.
    private func finish() async {
        hub.markSignedIn()
        setupError = nil
        do {
            let (route, _) = try await hub.inspect()
            if route == .firstDevice {
                try await hub.createFirstBlob()
            }
            onFinished(route)
        } catch {
            setupError = SignInMessages.text(for: error)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Onboarding.Account.title)
                    .font(BanditoFont.font(size: 38, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Onboarding.Account.subtitle)
                    .font(BanditoFont.font(size: 15, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
            }
            if let setupError {
                HStack(spacing: 10) {
                    Text(setupError)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                    // Checking the account and creating the first blob are safe to repeat.
                    Button(L10n.Onboarding.Server.retry) { Task { await finish() } }
                        .buttonStyle(QuietButtonStyle(size: .regular))
                }
            }
            Button {
                models?.github.start()
                showGitHub = true
            } label: {
                Text(L10n.Onboarding.Account.continueGithub)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LightPillButtonStyle(size: .large))
            .disabled(models == nil)

            divider(L10n.Onboarding.Account.orEmail)

            if let models {
                EmailBlock(model: models.email)
            }

            privacyCard
            Text(L10n.Onboarding.Account.iphoneHint)
                .font(BanditoFont.font(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            Button {
                onSkipAccount?()
            } label: {
                Text(L10n.Onboarding.Account.skip)
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                + Text(" · \(L10n.Onboarding.Account.skipHint)")
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            .buttonStyle(.plain)
            .opacity(onSkipAccount == nil ? 0 : 1)
            .disabled(onSkipAccount == nil)
        }
    }

    private func divider(_ label: String) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.Bandito.text.opacity(0.08)).frame(height: 1)
            Text(label)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            Rectangle().fill(Color.Bandito.text.opacity(0.08)).frame(height: 1)
        }
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AvatarColor.sage.color)
                .padding(.top, 1)
            Text(L10n.Onboarding.Account.privacy)
                .font(BanditoFont.font(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
        }
        .padding(14)
        .background(AvatarColor.sage.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AvatarColor.sage.color.opacity(0.18)))
    }
}

/// The email branch: the address field, then the six code boxes, the resend wait and "another email".
private struct EmailBlock: View {
    @Bindable var model: EmailSignInModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.phase == .address {
                HStack(spacing: 8) {
                    TextField(L10n.Onboarding.Account.emailPlaceholder, text: $model.email)
                        .textFieldStyle(.plain)
                        .font(BanditoFont.font(size: 14.5, weight: 400))
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.text.opacity(0.12)))
                        .onSubmit { Task { await model.sendCode(now: Date()) } }
                        .accessibilityLabel(L10n.Onboarding.Account.emailLabel)
                    Button(L10n.Onboarding.Account.sendCode) {
                        Task { await model.sendCode(now: Date()) }
                    }
                    .buttonStyle(SignalButtonStyle())
                    .disabled(model.isBusy)
                }
            } else {
                Text(L10n.Onboarding.Account.codeHint(email: model.email))
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                CodeBoxes(model: model)
                HStack(spacing: 14) {
                    ResendControl(model: model)
                    Button(L10n.Onboarding.Account.changeEmail) { model.changeEmail() }
                        .buttonStyle(.plain)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
                if model.isBusy {
                    Text(L10n.Onboarding.Account.checking)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            if let error = model.errorText {
                Text(error)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
        }
    }
}

/// Six boxes. Typing moves on to the next box; a paste fills from the box it lands in; a complete code is checked.
private struct CodeBoxes: View {
    @Bindable var model: EmailSignInModel
    @FocusState private var focused: Int?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<SixDigitCode.length, id: \.self) { index in
                TextField("", text: binding(for: index))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(BanditoFont.font(size: 22, weight: 600, mono: true))
                    .foregroundStyle(Color.Bandito.text)
                    .frame(width: 44, height: 56)
                    .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(focused == index ? Color.Bandito.signal : Color.Bandito.text.opacity(0.12)))
                    .focused($focused, equals: index)
                    .accessibilityLabel(L10n.Onboarding.Account.codeDigit(index: String(index + 1)))
                    .accessibilityValue(model.code.slots[index] ?? "")
            }
        }
        .onAppear { focused = 0 }
    }

    /// What the box shows is the model's slot. Input is taken from the change: the new character of a
    /// box that already holds a digit, or the whole text of a paste.
    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { model.code.slots[index] ?? "" },
            set: { newValue in
                let previous = model.code.slots[index] ?? ""
                if newValue.isEmpty {
                    model.clearBox(at: index)
                    focused = max(index - 1, 0)
                    return
                }
                let typed = newValue.count > 1 && newValue.hasPrefix(previous)
                    ? String(newValue.dropFirst(previous.count)) : newValue
                let digits = typed.filter { $0.isASCII && $0.isNumber }.count
                Task {
                    await model.enter(typed, at: index)
                    focused = min(index + max(digits, 1), SixDigitCode.length - 1)
                }
            })
    }
}

/// "Send a new code", with the seconds left while the server's wait runs.
private struct ResendControl: View {
    var model: EmailSignInModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = model.cooldown.remaining(now: context.date)
            Button(left > 0 ? L10n.Onboarding.Account.resendIn(seconds: String(left)) : L10n.Onboarding.Account.resend) {
                Task { await model.resend(now: Date()) }
            }
            .buttonStyle(.plain)
            .font(BanditoFont.font(size: 13, weight: 500))
            .foregroundStyle(left > 0 ? Color.Bandito.text3 : Color.Bandito.signal)
            .disabled(left > 0 || model.isBusy)
        }
    }
}

/// The GitHub device flow in a sheet: the code in large type (copied already), the page button, the wait.
struct GitHubSignInSheet: View {
    @Bindable var model: GitHubSignInModel
    var close: () -> Void

    @State private var copiedNote = false

    var body: some View {
        VStack(spacing: 18) {
            Text(L10n.Onboarding.Account.Github.title)
                .font(BanditoFont.font(size: 20, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            content
            Button(L10n.Common.cancel, action: close)
                .buttonStyle(QuietButtonStyle())
        }
        .padding(28)
        .frame(width: 420)
        .background(Color.Bandito.surface2)
        .onChange(of: model.state) { _, state in
            if case .signedIn = state { close() }
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .connecting, .signedIn:
            ProgressView().controlSize(.small)
            Text(L10n.Onboarding.Account.Github.connecting)
                .foregroundStyle(Color.Bandito.text2)
        case .waiting(let flow):
            Text(UserCodeFormat.grouped(flow.userCode))
                .font(BanditoFont.font(size: 36, weight: 600, mono: true))
                .foregroundStyle(Color.Bandito.text)
                .tracking(3)
                .textSelection(.enabled)
            Button(L10n.Onboarding.Account.Github.copyAndOpen) {
                model.copyAndOpen()
                copiedNote = true
            }
            .buttonStyle(SignalButtonStyle())
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
        case .expired:
            failure(L10n.Onboarding.Account.Github.expired)
        case .denied:
            failure(L10n.Onboarding.Account.Github.denied)
        case .failed(let message):
            failure(message)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.Bandito.danger)
            Button(L10n.Onboarding.Account.Github.retry) {
                copiedNote = false
                model.start()
            }
            .buttonStyle(SignalButtonStyle())
        }
    }
}
