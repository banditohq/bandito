import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Bottom of the sidebar: the profile (avatar, nickname or e-mail, and the server or "not signed in") and the usage
/// button. The profile opens the account card: the account when someone is signed in, the sign-in when nobody is.
struct SidebarFooter: View {
    @Environment(Router.self) private var router
    @Environment(AccountHub.self) private var hub
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Button {
                router.sheet = .account
            } label: {
                HStack(spacing: 10) {
                    ProfileAvatar(name: name, color: AvatarColor.at(hub.profile.colorIndex), picture: hub.avatar.image, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(BanditoFont.font(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(BanditoFont.font(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 12))
            .help(L10n.Account.title)
            .accessibilityLabel(L10n.Account.title)
            .frame(maxWidth: .infinity)

            MarketButton()
            UsageButton()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.Bandito.text.opacity(0.06))
                .frame(height: 1)
        }
        .task { await hub.refreshAccount() }
    }

    /// The nickname the person set, else the account's name or e-mail. Nil when nobody is signed in.
    private var name: String? {
        guard hub.signedIn else { return nil }
        return ProfileNames.displayName(nickname: hub.profile.nickname, account: hub.me?.user)
    }

    private var title: String {
        guard hub.signedIn else { return L10n.Account.title }
        return name ?? L10n.Account.title
    }

    /// The server this Mac works with, or "Not signed in" when nobody is.
    private var subtitle: String {
        guard hub.signedIn else { return L10n.Account.notSignedIn }
        return app.currentServer.map(ServerPicker.name) ?? ""
    }
}

/// The Marketplace button between the profile and the usage pill: a square icon button, lit while the Marketplace
/// is on show.
private struct MarketButton: View {
    @Environment(Router.self) private var router

    var body: some View {
        let open = router.mode == .market
        Button {
            router.select(mode: .market)
        } label: {
            Image(systemName: AppMode.market.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(open ? Color.Bandito.text : Color.Bandito.text2)
        }
        .banditoButton(.icon(size: 34, label: L10n.Mode.market))
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.Bandito.text.opacity(open ? 0.12 : 0)))
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}
