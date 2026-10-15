import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The profile sheet (420 wide, as tall as its content): the photo and the name in one row, one card with the devices of
/// the account, this Mac's code under it, the sync line, and sign-out and reset at the foot. Without a session the sheet
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
    @State private var connectingPhone = false
    @State private var joiningPhone: JoinQRRequest?
    @State private var codeOpen = false
    @State private var avatarHovered = false
    @State private var photoOptionsOpen = false
    @FocusState private var nicknameFocused: Bool
    /// A photo picked for the profile, framed in the sheet until it is saved.
    @State private var photoFraming: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: ProfileSheetLayout.groupSpacing) {
            content
            if let errorText, !showsErrorInPage {
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
        .banditoSheet(isPresented: $connectingPhone, dismissOnOutsideClick: false) {
            ConnectPhoneWizard()
        }
        .banditoSheet(item: $joiningPhone, dismissOnOutsideClick: false) { _ in
            JoinQRSheet()
        }
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
        .confirmationDialog(
            L10n.Account.Photo.change,
            isPresented: $photoOptionsOpen,
            titleVisibility: .hidden
        ) {
            Button(L10n.Account.Photo.choose) { pickPhoto() }
            if hub.avatar.image != nil {
                Button(L10n.Account.Photo.remove) { removePhoto() }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
    }

    /// The approval step: this Mac waits for another device to confirm it.
    private var isApprovalRoute: Bool {
        route == .waitForApproval || route == .recoverRequired
    }

    /// The page with the account (header, devices, sync) shows its errors on the sync line; anything else shows below.
    private var showsErrorInPage: Bool {
        hub.signedIn && hub.me != nil && !isApprovalRoute
    }

    @ViewBuilder
    private var content: some View {
        if !hub.signedIn {
            ProfileSignInBlock {
                Task { await finishSignIn() }
            }
        } else if isApprovalRoute {
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
                devicesCard(me)
                thisMacCode
                syncLine
                actions
            }
        } else if loading || errorText == nil {
            // Reading the account after a sign-in, or before the first answer: a spinner, not an empty card.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BanditoSpace.s6)
        }
    }

    // MARK: - Header

    /// One row: the photo on the left, the name with its pencil, the e-mail under it (with the GitHub mark when the
    /// person signs in with GitHub), and the colour choice when there is no photo. The trailing space keeps the name
    /// clear of the close button.
    private func identityHeader(_ me: Me) -> some View {
        let name = ProfileNames.displayName(nickname: hub.profile.nickname, account: me.user)
        return HStack(alignment: .center, spacing: BanditoSpace.s4) {
            avatarButton(name: name)
            VStack(alignment: .leading, spacing: 3) {
                if editingNickname {
                    nicknameEditor
                } else {
                    nicknameLine(name: name, me: me)
                }
                emailLine(me)
                if hub.avatar.image == nil {
                    colorChoice.padding(.top, BanditoSpace.s1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, BanditoSpace.s8)
    }

    /// The profile photo, 56 pt. A click asks what to do with it: choose a photo, or remove the one there is. A camera
    /// badge shows while the pointer is over it.
    private func avatarButton(name: String?) -> some View {
        let size = ProfileSheetLayout.avatarSize
        return Button {
            photoOptionsOpen = true
        } label: {
            ProfileAvatar(
                name: name, color: AvatarColor.at(hub.profile.colorIndex), picture: hub.avatar.image, size: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .frame(width: 22, height: 22)
                        .background(Color.Bandito.surface3, in: Circle())
                        .overlay(Circle().stroke(Color.Bandito.line, lineWidth: 1))
                        .offset(x: 2, y: 2)
                        .opacity(avatarHovered ? 1 : 0)
                        .banditoAnimation(BanditoMotion.ease, value: avatarHovered)
                }
        }
        .banditoButton(.row(cornerRadius: size / 2, hoverOpacity: 0.05))
        .onHover { avatarHovered = $0 }
        .help(L10n.Account.Photo.change)
        .accessibilityLabel(L10n.Account.Photo.change)
    }

    /// The name; a click on it or on the pencil edits it in place.
    private func nicknameLine(name: String?, me: Me) -> some View {
        Button {
            nicknameDraft = hub.profile.nickname.isEmpty ? (me.user.name ?? "") : hub.profile.nickname
            editingNickname = true
        } label: {
            HStack(spacing: BanditoSpace.s2) {
                Text(name ?? L10n.Account.title)
                    .font(BanditoFont.display(size: 18.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.Bandito.text3)
            }
            .padding(.horizontal, BanditoSpace.s2)
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
                .frame(width: 220)
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

    /// The e-mail, with the GitHub mark in front of it when the person signs in with GitHub.
    private func emailLine(_ me: Me) -> some View {
        HStack(spacing: 6) {
            if me.user.githubLogin != nil {
                GitHubMark()
                    .fill(Color.Bandito.text3)
                    .frame(width: 11, height: 11)
                    .help(L10n.Account.Method.github)
                    .accessibilityLabel(L10n.Account.Method.github)
            }
            Text(me.user.email ?? me.user.githubLogin.map { "@\($0)" } ?? "")
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
            .padding(BanditoSpace.s4)
            .banditoCard()
        }
    }

    // MARK: - Devices

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.Bandito.text.opacity(0.07))
            .frame(height: 1)
    }

    /// One card: the devices of the account, one line each, and the main action at its foot.
    private func devicesCard(_ me: Me) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: BanditoSpace.s2) {
                SectionLabel(L10n.Account.Section.devices)
                Spacer(minLength: BanditoSpace.s2)
                connectPhoneButton
            }
            .padding(.horizontal, BanditoSpace.s4)
            .padding(.top, BanditoSpace.s3)
            .padding(.bottom, BanditoSpace.s2)
            ForEach(Array(me.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { groupDivider }
                deviceRow(device)
            }
            groupDivider
            addIPhoneButton
                .frame(maxWidth: .infinity)
                .padding(BanditoSpace.s4)
        }
        .banditoCard()
    }

    /// «Добавить iPhone или iPad»: the join QR code, the iPhone signs in with a scan. The main action of the sheet.
    private var addIPhoneButton: some View {
        Button {
            joiningPhone = JoinQRRequest()
        } label: {
            Label(L10n.Account.Devices.addIPhone, systemImage: "qrcode")
        }
        .banditoButton(.signal(fillsWidth: true))
    }

    /// The wizard that connects an iPhone through the cloud. Still reachable from this card; see the report.
    private var connectPhoneButton: some View {
        Button {
            connectingPhone = true
        } label: {
            Label(L10n.Account.Devices.connectPhone, systemImage: "iphone.gen3")
                .font(BanditoFont.text(size: 12, weight: 500))
        }
        .banditoButton(.quiet(size: .compact))
        .fixedSize()
    }

    private func deviceRow(_ device: AccountDevice) -> some View {
        HStack(spacing: BanditoSpace.s3) {
            Image(systemName: DeviceIcon.symbol(platform: device.platform, name: device.name))
                .font(.system(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 28, height: 28)
                .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BanditoSpace.s2) {
                    Text(device.name)
                        .font(BanditoFont.text(size: 13.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if device.current {
                        Chip(text: L10n.Account.Section.thisMac)
                    }
                }
                if let status = deviceStatus(device) {
                    Text(status)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: BanditoSpace.s2)
            if !device.current {
                deviceMoreButton(device)
            }
        }
        .padding(.horizontal, BanditoSpace.s4)
        .padding(.vertical, BanditoSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The «…» of another device: a click asks to disconnect it, through the confirmation that says what happens.
    private func deviceMoreButton(_ device: AccountDevice) -> some View {
        Button {
            removing = device
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
        }
        .banditoButton(.icon(size: 28, label: L10n.Account.Device.menu))
    }

    /// What a device's line says: «в сети» or «был в сети …», from its last sign-in time.
    private func deviceStatus(_ device: AccountDevice) -> String? {
        switch DevicePresence.line(current: device.current, lastSeen: Self.date(from: device.lastSeenAt), now: Date()) {
        case .online:
            return L10n.Account.Device.online
        case .lastSeen(let date):
            return L10n.Account.Device.lastSeen(when: date.formatted(.relative(presentation: .named)))
        case .none:
            return nil
        }
    }

    // MARK: This Mac's code

    /// «Код проверки этого Mac»: folded by default. Opened, it shows the code in mono, with a copy button and why it is
    /// there.
    private var thisMacCode: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            Button {
                codeOpen.toggle()
            } label: {
                HStack(spacing: BanditoSpace.s2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(codeOpen ? 90 : 0))
                        .frame(width: 12)
                    Text(L10n.Account.Code.title)
                        .font(BanditoFont.text(size: 12.5, weight: 500))
                    Spacer(minLength: BanditoSpace.s2)
                }
                .foregroundStyle(Color.Bandito.text2)
                .padding(.horizontal, BanditoSpace.s2)
                .padding(.vertical, BanditoSpace.s1 + 2)
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 8, hoverOpacity: 0.05))
            if codeOpen {
                VStack(alignment: .leading, spacing: BanditoSpace.s2) {
                    HStack(spacing: BanditoSpace.s2) {
                        Text(hub.identity?.fingerprint ?? "")
                            .font(BanditoFont.mono(size: 14, weight: 500))
                            .foregroundStyle(Color.Bandito.text)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .fixedSize()
                        Button {
                            SystemActions.copy(hub.identity?.fingerprint ?? "")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .banditoButton(.icon(size: 26, label: L10n.Account.copyCode))
                        .disabled(hub.identity == nil)
                    }
                    Text(L10n.Account.ThisMac.hint)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, BanditoSpace.s2)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoAnimation(BanditoMotion.ease, value: codeOpen)
    }

    // MARK: Sync

    /// One quiet line: a green dot and «Синхронизировано · Синхронизировать сейчас». A failure turns the dot red and
    /// shows its text in place of the line.
    private var syncLine: some View {
        HStack(spacing: BanditoSpace.s2) {
            Circle()
                .fill(errorText == nil ? Color.Bandito.ok : Color.Bandito.danger)
                .frame(width: 7, height: 7)
            if let errorText {
                Text(errorText.text)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if errorText.canRetry {
                    Button(L10n.Banner.retry) {
                        Task { await syncNow() }
                    }
                    .banditoButton(.link)
                    .font(BanditoFont.text(size: 12, weight: 500))
                    .fixedSize()
                    .disabled(syncing)
                }
            } else {
                Group {
                    if let lastSynced {
                        Text(L10n.Account.Sync.done(when: lastSynced.formatted(.relative(presentation: .named))))
                    } else {
                        Text(L10n.Account.Sync.synced)
                    }
                }
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .help(L10n.Account.Sync.what)
                Text("·")
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                Button(L10n.Account.Sync.now) {
                    Task { await syncNow() }
                }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 12, weight: 500))
                .fixedSize()
                .disabled(syncing)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Foot

    /// Sign-out on the left, the reset (danger) on the right, both small. Help is a quiet link under them: the Mac's
    /// Settings are in the application menu (⌘,), and help is not.
    private var actions: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            HStack(spacing: BanditoSpace.s4) {
                Button(L10n.Onboarding.Account.signOutAction) {
                    confirmingSignOut = true
                }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 12, weight: 500))
                Spacer(minLength: BanditoSpace.s2)
                Button(L10n.Onboarding.Account.resetAccountAction) {
                    resetting.toggle()
                }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 12, weight: 500))
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
            if let help = URL(string: "mailto:hello@bandito.dev") {
                Button(L10n.Account.Links.help) {
                    SystemActions.open(help)
                }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 11.5, weight: 500))
                .frame(maxWidth: .infinity, alignment: .leading)
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
            // A lost phone loses its access to the servers too (revoked on every server this Mac can reach).
            await hub.revokeAccess(of: device)
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

/// What a device's line in the account says about it. A device that was seen in the last five minutes is online; the
/// one this Mac is always is. Otherwise the line says when it was last seen.
enum DevicePresence {
    /// How long after its last sign-in a device still counts as online.
    static let onlineWindow: TimeInterval = 5 * 60

    enum Line: Equatable {
        case online
        case lastSeen(Date)
        case none
    }

    static func line(current: Bool, lastSeen: Date?, now: Date) -> Line {
        if current { return .online }
        guard let lastSeen else { return .none }
        return now.timeIntervalSince(lastSeen) < onlineWindow ? .online : .lastSeen(lastSeen)
    }
}
