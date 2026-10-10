import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Account. Reads the same `AccountHub` as the main window, so both show one state. Signing in and the
/// profile card live in the main window (the sheet is shared with onboarding), so both open there.
struct AccountSection: View {
    @Environment(Router.self) private var router
    @Environment(AccountHub.self) private var hub

    @State private var confirmingSignOut = false
    @State private var signingOut = false
    @State private var errorText: UserFacingMessage?

    var body: some View {
        SettingsPage(title: SettingsSection.account.title, intro: L10n.Settings.Account.intro) {
            if hub.signedIn {
                signedInCards
            } else {
                signedOutCard
            }
        }
        // Reads the account when the page opens, so a sign-in made in the main window shows here at once.
        .task { await hub.refreshAccount() }
        .confirmationDialog(
            L10n.Account.SignOut.title,
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button(L10n.Account.SignOut.confirm) {
                Task { await signOut(forgetThisMac: false) }
            }
            Button(L10n.Account.SignOut.forget, role: .destructive) {
                Task { await signOut(forgetThisMac: true) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Account.SignOut.message)
        }
    }

    // MARK: - Signed out

    private var signedOutCard: some View {
        VStack(spacing: 0) {
            SettingsRow(title: L10n.Settings.Account.state, hint: L10n.Settings.Account.signedOutHint) {
                Button(L10n.Settings.Account.signIn) {
                    openInMainWindow { $0.sheet = .account }
                }
                .banditoButton(.signal())
                .fixedSize()
            }
        }
        .banditoCard()
    }

    // MARK: - Signed in

    private var signedInCards: some View {
        let name = ProfileNames.displayName(nickname: hub.profile.nickname, account: hub.me?.user)
        return VStack(alignment: .leading, spacing: 14) {
            identity(name: name)
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.Account.state, hint: L10n.Settings.Account.openProfileHint) {
                    Button(L10n.Settings.Account.openProfile) {
                        openInMainWindow { $0.sheet = .account }
                    }
                    .banditoButton(.quiet())
                    .fixedSize()
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Onboarding.Account.signOutAction, hint: L10n.Account.SignOut.message) {
                    Button(L10n.Onboarding.Account.signOutAction) {
                        confirmingSignOut = true
                    }
                    .banditoButton(.quiet())
                    .fixedSize()
                    .disabled(signingOut)
                }
            }
            .banditoCard()
            if let errorText {
                UserFacingErrorView(message: errorText)
            }
        }
    }

    private func identity(name: String?) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ProfileAvatar(name: name, color: AvatarColor.at(hub.profile.colorIndex), picture: hub.avatar.image, size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(name ?? L10n.Account.title)
                    .font(BanditoFont.font(size: 18, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let user = hub.me?.user {
                    Text(user.email ?? user.githubLogin.map { "@\($0)" } ?? "")
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    loginMethod(isGitHub: user.githubLogin != nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }

    private func loginMethod(isGitHub: Bool) -> some View {
        HStack(spacing: 6) {
            if isGitHub {
                GitHubMark()
                    .fill(Color.Bandito.text2)
                    .frame(width: 12, height: 12)
                Text(L10n.Account.Method.github)
            } else {
                Image(systemName: "envelope")
                    .font(.system(size: 11))
                Text(L10n.Account.Method.email)
            }
        }
        .font(BanditoFont.font(size: 12, weight: 500))
        .foregroundStyle(Color.Bandito.text2)
        .lineLimit(1)
    }

    // MARK: - Actions

    /// The account card and the sign-in live in the main window: Settings closes and the main window comes forward.
    private func openInMainWindow(_ route: (Router) -> Void) {
        SettingsHandoff.openMainWindow(router: router, route)
    }

    /// Signs out after the person confirmed it. On failure nothing is cleared: the message shows and the page stays.
    private func signOut(forgetThisMac: Bool) async {
        signingOut = true
        defer { signingOut = false }
        do {
            try await hub.signOut(forgetThisMac: forgetThisMac)
            errorText = nil
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }
}
