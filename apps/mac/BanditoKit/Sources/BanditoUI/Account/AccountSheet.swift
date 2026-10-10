import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The profile sheet (460 wide, as tall as its content): the photo, the nickname and e-mail, then one card with this
/// Mac's code, the devices of the account and sync, the links to settings and help, and sign-out. Without a session the
/// sheet shows the sign-in instead.
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
    @FocusState private var nicknameFocused: Bool
    /// A photo picked for the profile, framed in the sheet until it is saved.
    @State private var photoFraming: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: ProfileSheetLayout.groupSpacing) {
            content
            if let errorText {
                UserFacingErrorView(message: errorText)
            }
        }
        .padding(ProfileSheetLayout.padding)
        .frame(width: ProfileSheetLayout.width, alignment: .leading)
        .background(Color.Bandito.surface2)
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .banditoButton(.icon(size: 28, label: L10n.Common.close))
            .help(L10n.Common.close)
            .padding(12)
        }
        .task { await reload() }
        .confirmationDialog(
            L10n.Account.SignOut.title,
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button(L10n.Account.SignOut.confirm) {
                Task { await signOut() }
            }
            Button(L10n.Account.SignOut.forget, role: .destructive) {
                Task { await signOut(forgetThisMac: true) }
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
            photoFramingBlock
            // While a photo is being framed the rest waits, so the sheet stays as tall as the screen allows.
            if photoFraming == nil {
                groupsCard(me)
                linksCard
                actions
            }
        } else if loading || errorText == nil {
            // Reading the account after a sign-in, or before the first answer: a spinner, not an empty card.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
    }

    // MARK: - Header

    /// The centred head of the profile: the photo with its camera button, the name, the e-mail, how the person signed
    /// in, and either the colour choice (no photo) or the way to remove the photo.
    private func identityHeader(_ me: Me) -> some View {
        let name = ProfileNames.displayName(nickname: hub.profile.nickname, account: me.user)
        return VStack(spacing: 10) {
            photoButton(name: name)
            if editingNickname {
                nicknameEditor
            } else {
                nicknameLine(name: name, me: me)
            }
            Text(me.user.email ?? me.user.githubLogin.map { "@\($0)" } ?? "")
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .truncationMode(.middle)
            loginMethod(me)
            if hub.avatar.image == nil {
                colorChoice.padding(.top, 2)
            } else {
                Button(L10n.Account.Photo.remove) { removePhoto() }
                    .banditoButton(.link)
                    .font(BanditoFont.text(size: 12, weight: 500))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The profile photo, 88 pt, with a small round camera button at its lower edge: a click picks a new photo.
    private func photoButton(name: String?) -> some View {
        let size = ProfileSheetLayout.avatarSize
        return ProfileAvatar(
            name: name, color: AvatarColor.at(hub.profile.colorIndex), picture: hub.avatar.image, size: size)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    pickPhoto()
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .frame(width: 28, height: 28)
                        .background(Color.Bandito.surface3, in: Circle())
                        .overlay(Circle().stroke(Color.Bandito.line, lineWidth: 1))
                        .overlay(Circle().stroke(Color.Bandito.surface2, lineWidth: 3).padding(-3))
                }
                .banditoButton(.row(cornerRadius: 14, hoverOpacity: 0.12))
                .help(L10n.Account.Photo.change)
                .accessibilityLabel(L10n.Account.Photo.change)
                .offset(x: 2, y: 2)
            }
    }

    /// The name; a click on it or on the pencil edits it in place.
    private func nicknameLine(name: String?, me: Me) -> some View {
        Button {
            nicknameDraft = hub.profile.nickname.isEmpty ? (me.user.name ?? "") : hub.profile.nickname
            editingNickname = true
        } label: {
            HStack(spacing: 8) {
                Text(name ?? L10n.Account.title)
                    .font(BanditoFont.display(size: 18.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.Bandito.text3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .banditoButton(.row(cornerRadius: 10, hoverOpacity: 0.06))
        .help(L10n.Account.Nickname.edit)
        .accessibilityLabel(L10n.Account.Nickname.edit)
    }

    /// The name field in the place of the name: Return or the check saves, Escape or the cross leaves it as it was.
    private var nicknameEditor: some View {
        HStack(spacing: 6) {
            TextField(L10n.Account.Nickname.placeholder, text: $nicknameDraft)
                .banditoField()
                .font(BanditoFont.text(size: 16, weight: 500))
                .multilineTextAlignment(.center)
                .frame(width: 240)
                .focused($nicknameFocused)
                .onSubmit { saveNickname() }
                .onExitCommand { editingNickname = false }
                .accessibilityLabel(L10n.Account.Nickname.edit)
            Button {
                saveNickname()
            } label: {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
            }
            .banditoButton(.icon(size: 28, label: L10n.Common.save))
            Button {
                editingNickname = false
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
            }
            .banditoButton(.icon(size: 28, label: L10n.Common.cancel))
        }
        .onAppear { nicknameFocused = true }
    }

    private func saveNickname() {
        hub.profile.setNickname(nicknameDraft)
        editingNickname = false
    }

    /// A small badge: how this account signs in.
    private func loginMethod(_ me: Me) -> some View {
        HStack(spacing: 5) {
            if me.user.githubLogin != nil {
                GitHubMark()
                    .fill(Color.Bandito.text2)
                    .frame(width: 11, height: 11)
                Text(L10n.Account.Method.github)
            } else {
                Image(systemName: "envelope")
                    .font(.system(size: 10))
                Text(L10n.Account.Method.email)
            }
        }
        .font(BanditoFont.text(size: 11.5, weight: 500))
        .foregroundStyle(Color.Bandito.text2)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
    }

    private var colorChoice: some View {
        HStack(spacing: 6) {
            ForEach(Array(AvatarColor.allCases.enumerated()), id: \.offset) { index, color in
                let selected = index == hub.profile.colorIndex
                Button {
                    hub.profile.setColorIndex(index)
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .stroke(selected ? Color.Bandito.text : Color.clear, lineWidth: 2)
                                .frame(width: 27, height: 27))
                        .frame(width: 28, height: 28)
                }
                .banditoButton(.row(cornerRadius: 14, hoverOpacity: 0.08))
                .help(Self.colorName(color))
                .accessibilityLabel(Self.colorName(color))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Account.avatarColor)
    }

    /// The photo is framed here, in the sheet under the head, so the frame always fits the sheet.
    @ViewBuilder
    private var photoFramingBlock: some View {
        if let image = photoFraming {
            PictureFraming(
                image: image,
                encode: { AvatarPicture.jpeg(image: $0, crop: $1) },
                maxBytes: AvatarPicture.profileMaxBytes,
                tooLargeText: L10n.Account.Photo.tooLarge,
                onSave: { data in
                    try await hub.avatar.setPicture(data, at: Self.nowMs())
                    photoFraming = nil
                    // The photo is saved on this Mac; a failing sync is shown on the sheet.
                    do {
                        try await hub.syncProfilePicture()
                    } catch {
                        errorText = SignInMessages.text(for: error)
                    }
                },
                onCancel: { photoFraming = nil },
                side: ProfileSheetLayout.cropSide,
                circular: true)
            .frame(maxWidth: .infinity)
            .padding(16)
            .banditoCard()
        }
    }

    // MARK: - Groups

    private func groupsCard(_ me: Me) -> some View {
        VStack(spacing: 0) {
            thisMacGroup
            groupDivider
            devicesGroup(me)
            groupDivider
            syncGroup
        }
        .banditoCard()
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.Bandito.text.opacity(0.07))
            .frame(height: 1)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: This Mac

    private var thisMacGroup: some View {
        group(L10n.Account.Section.thisMac) {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.Bandito.text2)
                    .frame(width: 28, height: 28)
                    .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(DeviceDescriptor.current.name)
                        .font(BanditoFont.text(size: 13.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(hub.identity?.fingerprint ?? "")
                            .font(BanditoFont.mono(size: 13, weight: 500))
                            .foregroundStyle(Color.Bandito.text2)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .fixedSize()
                        Button {
                            SystemActions.copy(hub.identity?.fingerprint ?? "")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .banditoButton(.icon(size: 24, label: L10n.Account.copyCode))
                        .disabled(hub.identity == nil)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(L10n.Account.ThisMac.hint)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Devices

    private func devicesGroup(_ me: Me) -> some View {
        group(L10n.Account.Section.devices) {
            VStack(spacing: 10) {
                ForEach(me.devices, id: \.id) { device in
                    deviceRow(device)
                }
            }
        }
    }

    private func deviceRow(_ device: AccountDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: DeviceIcon.symbol(platform: device.platform, name: device.name))
                .font(.system(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 28, height: 28)
                .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(BanditoFont.text(size: 13.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if device.current {
                        Text(L10n.Onboarding.Account.settingsThisDevice)
                            .font(BanditoFont.text(size: 11.5, weight: 500))
                            .foregroundStyle(Color.Bandito.signal)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                if !device.current, let seen = Self.date(from: device.lastSeenAt) {
                    Text(L10n.Account.Device.lastSeen(when: seen.formatted(.relative(presentation: .named))))
                        .font(BanditoFont.text(size: 12, weight: 400))
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
    }

    // MARK: Sync

    private var syncGroup: some View {
        group(L10n.Account.Section.sync) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.Bandito.ok)
                    .frame(width: 7, height: 7)
                Group {
                    if let lastSynced {
                        Text(L10n.Account.Sync.done(when: lastSynced.formatted(.relative(presentation: .named))))
                    } else {
                        Text(L10n.Account.Sync.on)
                    }
                }
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .help(L10n.Account.Sync.what)
                Spacer(minLength: 8)
                Button(L10n.Account.Sync.now) {
                    Task { await syncNow() }
                }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .fixedSize()
                .disabled(syncing)
            }
        }
    }

    // MARK: - Links and actions

    private var linksCard: some View {
        VStack(spacing: 0) {
            Button {
                dismiss()
                WindowActions.showSettings()
            } label: {
                linkRow(icon: "gearshape", title: L10n.Account.Links.settings)
            }
            .banditoButton(.row(cornerRadius: 0))
            if let help = URL(string: "mailto:hello@bandito.dev") {
                groupDivider
                Button {
                    SystemActions.open(help)
                } label: {
                    linkRow(icon: "questionmark.circle", title: L10n.Account.Links.help)
                }
                .banditoButton(.row(cornerRadius: 0))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: BanditoCardModifier.cornerRadius, style: .continuous))
        .banditoCard()
    }

    private func linkRow(icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 20)
            Text(title)
                .font(BanditoFont.text(size: 13.5, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Bandito.text3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button(L10n.Onboarding.Account.signOutAction) {
                    confirmingSignOut = true
                }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 13, weight: 500))
                Spacer(minLength: 8)
                Button(L10n.Onboarding.Account.resetAccountAction) {
                    resetting.toggle()
                }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 13, weight: 500))
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
            try await hub.syncProfilePicture()
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
    private func signOut(forgetThisMac: Bool = false) async {
        do {
            try await hub.signOut(forgetThisMac: forgetThisMac)
            route = nil
            photoFraming = nil
            resetting = false
            errorText = nil
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }

    /// Picks a photo for the profile and frames it in the sheet. Nothing changes until the framing is saved.
    private func pickPhoto() {
        AvatarFilePanel.choose(message: L10n.Account.Photo.pickerMessage) { url in
            guard let url else { return }
            Task {
                guard let image = await Task.detached(operation: { AvatarImageFile.load(url) }).value else {
                    errorText = UserFacingMessage(text: L10n.Avatar.pictureUnreadable)
                    return
                }
                errorText = nil
                photoFraming = image
            }
        }
    }

    private func removePhoto() {
        Task {
            do {
                try await hub.avatar.removePicture(at: Self.nowMs())
                try await hub.syncProfilePicture()
                errorText = nil
            } catch {
                errorText = SignInMessages.text(for: error)
            }
        }
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
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
