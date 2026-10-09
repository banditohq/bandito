import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The profile card (520 wide, as tall as its content): who is signed in, the nickname and the avatar colour, this
/// Mac's code, the devices of the account, sync, and the links to settings and help. Without a session the card
/// shows the sign-in instead.
struct AccountSheet: View {
    @Environment(AccountHub.self) private var hub
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var route: AccountRoute?
    @State private var loading = false
    @State private var errorText: UserFacingMessage?
    @State private var resetting = false
    @State private var editingNickname = false
    @State private var nicknameDraft = ""
    @State private var removing: AccountDevice?
    @State private var confirmingSignOut = false
    @State private var lastSynced: Date?
    @State private var syncing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .banditoButton(.icon(size: 28, label: L10n.Common.close))
                .help(L10n.Common.close)
            }
            content
            if let errorText {
                UserFacingErrorView(message: errorText)
            }
        }
        .padding(28)
        .frame(width: 520, alignment: .leading)
        .background(Color.Bandito.surface2)
        .task { await reload() }
        .confirmationDialog(
            L10n.Account.SignOut.title,
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button(L10n.Account.SignOut.confirm, role: .destructive) {
                Task { await signOut() }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Account.SignOut.message)
        }
        .confirmationDialog(
            L10n.Account.Device.disconnectTitle(name: removing?.name ?? ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { device in
            Button(L10n.Account.Device.disconnect, role: .destructive) {
                Task { await remove(device) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Account.Device.disconnectMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hub.signedIn {
            ProfileSignInBlock {
                Task { await finishSignIn() }
            }
        } else if let route, route == .waitForApproval || route == .recoverRequired {
            DeviceApprovalStep {
                Task { await reload() }
            } onNoAccess: {
                Task { await signOut() }
            }
        } else if let me = hub.me {
            identityHeader(me)
            thisMacSection
            devicesSection(me)
            syncSection
            linksSection
            actions
        } else if loading || errorText == nil {
            // Reading the account after a sign-in, or before the first answer: a spinner, not an empty card.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
    }

    // MARK: - Header

    private func identityHeader(_ me: Me) -> some View {
        let name = ProfileNames.displayName(nickname: hub.profile.nickname, account: me.user)
        return HStack(alignment: .top, spacing: 16) {
            ProfileAvatar(name: name, color: AvatarColor.at(hub.profile.colorIndex), size: 56)
            VStack(alignment: .leading, spacing: 6) {
                if editingNickname {
                    nicknameEditor(me)
                } else {
                    nicknameLine(name: name, me: me)
                }
                Text(me.user.email ?? me.user.githubLogin.map { "@\($0)" } ?? "")
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                loginMethod(me)
                colorChoice
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nicknameLine(name: String?, me: Me) -> some View {
        HStack(spacing: 8) {
            Text(name ?? L10n.Account.title)
                .font(BanditoFont.font(size: 20, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                nicknameDraft = hub.profile.nickname.isEmpty ? (me.user.name ?? "") : hub.profile.nickname
                editingNickname = true
            } label: {
                Image(systemName: "pencil")
            }
            .banditoButton(.icon(size: 24, label: L10n.Account.Nickname.edit))
            .help(L10n.Account.Nickname.edit)
        }
    }

    private func nicknameEditor(_ me: Me) -> some View {
        HStack(spacing: 8) {
            TextField(L10n.Account.Nickname.placeholder, text: $nicknameDraft)
                .textFieldStyle(.plain)
                .font(BanditoFont.font(size: 15, weight: 500))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 10))
                .onSubmit { saveNickname() }
            Button(L10n.Common.save) { saveNickname() }
                .banditoButton(.signal())
                .fixedSize()
            Button(L10n.Common.cancel) { editingNickname = false }
                .banditoButton(.quiet())
                .fixedSize()
        }
    }

    private func saveNickname() {
        hub.profile.setNickname(nicknameDraft)
        editingNickname = false
    }

    private func loginMethod(_ me: Me) -> some View {
        HStack(spacing: 6) {
            if me.user.githubLogin != nil {
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

    private var colorChoice: some View {
        HStack(spacing: 8) {
            ForEach(Array(AvatarColor.allCases.enumerated()), id: \.offset) { index, color in
                Button {
                    hub.profile.setColorIndex(index)
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle()
                                .stroke(index == hub.profile.colorIndex ? Color.Bandito.text : Color.clear, lineWidth: 2)
                                .padding(-3)
                        }
                        .frame(width: 22, height: 22)
                }
                .banditoButton(.icon(size: 22, label: Self.colorName(color)))
                .help(Self.colorName(color))
            }
        }
        .padding(.top, 4)
    }

    // MARK: - This Mac

    private var thisMacSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(L10n.Account.Section.thisMac)
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.Bandito.text2)
                    .frame(width: 30, height: 30)
                    .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(DeviceDescriptor.current.name)
                    .font(BanditoFont.font(size: 13.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            DeviceCodeText(code: hub.identity?.fingerprint ?? "")
            HStack(spacing: 12) {
                Button(L10n.Account.copyCode) {
                    SystemActions.copy(hub.identity?.fingerprint ?? "")
                }
                .banditoButton(.quiet())
                .fixedSize()
                .disabled(hub.identity == nil)
                Text(L10n.Account.ThisMac.hint)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }

    // MARK: - Devices

    private func devicesSection(_ me: Me) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L10n.Account.Section.devices)
            VStack(spacing: 0) {
                ForEach(Array(me.devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.Bandito.text.opacity(0.06))
                            .frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                    deviceRow(device)
                }
            }
            .banditoCard()
        }
    }

    private func deviceRow(_ device: AccountDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: DeviceIcon.symbol(platform: device.platform, name: device.name))
                .font(.system(size: 15))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 30, height: 30)
                .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(BanditoFont.font(size: 13.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if device.current {
                        Text(L10n.Onboarding.Account.settingsThisDevice)
                            .font(BanditoFont.font(size: 11.5, weight: 500))
                            .foregroundStyle(Color.Bandito.signal)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if !device.current, let seen = Self.date(from: device.lastSeenAt) {
                    Text(L10n.Account.Device.lastSeen(when: seen.formatted(.relative(presentation: .named))))
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !device.current {
                Button(L10n.Account.Device.disconnect) {
                    removing = device
                }
                .banditoButton(.quiet())
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(L10n.Account.Section.sync)
            Text(L10n.Account.Sync.what)
                .font(BanditoFont.font(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.Bandito.ok)
                    .frame(width: 7, height: 7)
                if let lastSynced {
                    Text(L10n.Account.Sync.done(when: lastSynced.formatted(.relative(presentation: .named))))
                } else {
                    Text(L10n.Account.Sync.on)
                }
                Spacer(minLength: 8)
                Button(L10n.Account.Sync.now) {
                    Task { await syncNow() }
                }
                .banditoButton(.quiet())
                .fixedSize()
                .disabled(syncing)
            }
            .font(BanditoFont.font(size: 13, weight: 500))
            .foregroundStyle(Color.Bandito.text)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }

    // MARK: - Links and actions

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                dismiss()
                WindowActions.showSettings()
            } label: {
                linkRow(icon: "gearshape", title: L10n.Account.Links.settings)
            }
            .banditoButton(.row(cornerRadius: 10))
            if let help = URL(string: "mailto:hello@bandito.dev") {
                Button {
                    SystemActions.open(help)
                } label: {
                    linkRow(icon: "questionmark.circle", title: L10n.Account.Links.help)
                }
                .banditoButton(.row(cornerRadius: 10))
            }
        }
    }

    private func linkRow(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 20)
            Text(title)
                .font(BanditoFont.font(size: 13.5, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Bandito.text3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(L10n.Onboarding.Account.signOutAction) {
                    confirmingSignOut = true
                }
                .banditoButton(.quiet())
                .fixedSize()
                Spacer(minLength: 8)
                Button(L10n.Onboarding.Account.resetAccountAction) {
                    resetting.toggle()
                }
                .banditoButton(.link)
                .fixedSize()
                .foregroundStyle(Color.Bandito.danger)
            }
            if resetting {
                ResetConfirmation {
                    try await hub.recoverAccount()
                    resetting = false
                    await reload()
                } onCancel: {
                    resetting = false
                } onSignInAgain: {
                    Task { await signOut() }
                }
            }
        }
    }

    // MARK: - Actions

    private static func date(from iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: iso) ?? plain.date(from: iso)
    }

    /// Reads the route from the server. Without a session there is nothing to read.
    private func reload() async {
        guard hub.signedIn else {
            route = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            _ = try await hub.prepare()
            let (current, _) = try await hub.inspect()
            route = current
            errorText = nil
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }

    /// A sign-in that just succeeded: the first device creates the sync blob, then the card reads the account.
    private func finishSignIn() async {
        loading = true
        defer { loading = false }
        hub.markSignedIn()
        errorText = nil
        do {
            let (current, _) = try await hub.inspect()
            if current == .firstDevice {
                try await hub.createFirstBlob()
            }
        } catch {
            errorText = SignInMessages.text(for: error)
        }
        await reload()
    }

    private func syncNow() async {
        syncing = true
        defer { syncing = false }
        do {
            try await hub.publishServers(app.servers.map(\.config))
            lastSynced = Date()
            errorText = nil
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }

    private func remove(_ device: AccountDevice) async {
        do {
            try await hub.client?.deleteDevice(id: device.id, force: false)
            await reload()
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }

    /// Signs out after the person confirmed it. On failure nothing is cleared: the message shows and the card stays.
    private func signOut() async {
        do {
            try await hub.signOut()
            route = nil
            resetting = false
            errorText = nil
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }

    static func colorName(_ color: AvatarColor) -> String {
        switch color {
        case .peach: L10n.Account.Color.peach
        case .sky: L10n.Account.Color.sky
        case .sage: L10n.Account.Color.sage
        case .rose: L10n.Account.Color.rose
        case .lilac: L10n.Account.Color.lilac
        case .cream: L10n.Account.Color.cream
        }
    }
}
