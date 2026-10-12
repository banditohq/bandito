import BanditoDesign
import BanditoL10n
import SwiftUI
import UIKit

/// The Settings tab: servers, notifications, the Face ID lock, appearance and about. An insetGrouped list in Bandito's
/// fonts and tint. The choices live in `IOSSettings`; the servers in `ConnectedServers` (tokens in the Keychain).
struct SettingsTab: View {
    @Bindable var settings: IOSSettings
    let servers: ConnectedServers
    let biometrics: any BiometricAuthenticating
    let onConnect: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var permission = NotificationPermission.notDetermined
    @State private var pendingDisconnect: ConnectedServer?
    @State private var disconnectFailed = false
    @State private var faceIDRefused = false
    @State private var page: WebPage?

    var body: some View {
        NavigationStack {
            List {
                serversSection
                notificationsSection
                securitySection
                appearanceSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listRowBackground(Color.Bandito.surface1)
            .background(Color.Bandito.bg.ignoresSafeArea())
            .tint(Color.Bandito.signalFill)
            .navigationTitle(L10n.Settings.title)
            .task { await refreshPermission() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshPermission() }
            }
            .alert(
                L10n.Ios.Settings.Servers.disconnectTitle(name: pendingDisconnect?.name ?? ""),
                isPresented: isConfirmingDisconnect,
                presenting: pendingDisconnect
            ) { server in
                Button(L10n.Ios.Settings.Servers.disconnect, role: .destructive) { disconnect(server) }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: { server in
                Text(L10n.Ios.Settings.Servers.disconnectMessage(name: server.name))
            }
            .alert(L10n.Ios.Settings.Servers.removeFailed, isPresented: $disconnectFailed) {
                Button(L10n.Common.close, role: .cancel) {}
            }
            .sheet(item: $page) { SafariView(url: $0.url).ignoresSafeArea() }
        }
    }

    // MARK: Sections

    @ViewBuilder private var serversSection: some View {
        Section {
            if servers.servers.isEmpty {
                label(L10n.Server.noServer)
                    .foregroundStyle(Color.Bandito.text2)
            }
            ForEach(servers.servers) { server in
                ConnectedServerRow(server: server)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDisconnect = server
                        } label: {
                            Label(L10n.Ios.Settings.Servers.disconnect, systemImage: "xmark.circle")
                        }
                    }
            }
            Button(action: onConnect) {
                HStack(spacing: BanditoSpace.s2) {
                    Image(systemName: "plus.circle.fill")
                    actionLabel(L10n.Empty.NoServers.action)
                }
            }
        } header: {
            sectionHeader(L10n.Ios.Settings.Header.servers)
        }
    }

    @ViewBuilder private var notificationsSection: some View {
        Section {
            toggleRow(L10n.Ios.Settings.Notifications.approvals, isOn: $settings.notifyApprovals)
            toggleRow(L10n.Ios.Settings.Notifications.answers, isOn: $settings.notifyAnswers)
            toggleRow(L10n.Ios.Settings.Notifications.errors, isOn: $settings.notifyErrors)
            switch permission {
            case .allowed:
                EmptyView()
            case .notDetermined:
                Button {
                    Task { permission = await SystemNotifications.requestPermission() }
                } label: {
                    actionLabel(L10n.Ios.Settings.Notifications.allow)
                }
            case .denied:
                Button(action: openAppSettings) {
                    actionLabel(L10n.Ios.Settings.openSettings)
                }
            }
        } header: {
            sectionHeader(L10n.Ios.Settings.Header.notifications)
        } footer: {
            if permission == .denied {
                footnote(L10n.Ios.Settings.Notifications.denied)
            }
        }
    }

    @ViewBuilder private var securitySection: some View {
        Section {
            Toggle(isOn: faceIDBinding) {
                labelStack(L10n.Ios.Settings.Security.faceIDLock, hint: L10n.Ios.Settings.Security.faceIDLockHint)
            }
            .disabled(!settings.faceIDLock && !biometrics.isAvailable)
            if settings.faceIDLock {
                Picker(selection: $settings.lockTimeout) {
                    ForEach(LockTimeout.allCases, id: \.self) { timeout in
                        Text(L10n.Ios.Settings.Security.minutes(count: timeout.minutes)).tag(timeout)
                    }
                } label: {
                    label(L10n.Ios.Settings.Security.lockAfter)
                }
                .pickerStyle(.menu)
            }
            toggleRow(
                L10n.Ios.Settings.Security.riskyFaceID,
                hint: L10n.Ios.Settings.Security.riskyFaceIDHint,
                isOn: $settings.riskyNeedsFaceID)
        } header: {
            sectionHeader(L10n.Ios.Settings.Header.security)
        } footer: {
            if faceIDRefused {
                footnote(L10n.Ios.Settings.Security.failed, danger: true)
            } else if !biometrics.isAvailable {
                footnote(L10n.Ios.Settings.Security.unavailable)
            }
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: BanditoSpace.s2) {
                label(L10n.Settings.theme)
                Picker(L10n.Settings.theme, selection: $settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: BanditoSpace.s2) {
                labelStack(L10n.Ios.Settings.Appearance.reduceMotion, hint: L10n.Ios.Settings.Appearance.motionHint)
                Picker(L10n.Ios.Settings.Appearance.reduceMotion, selection: $settings.motion) {
                    ForEach(MotionPreference.allCases, id: \.self) { motion in
                        Text(motion.title).tag(motion)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Button(action: openAppSettings) {
                HStack {
                    label(L10n.Settings.language)
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
        } header: {
            sectionHeader(L10n.Ios.Settings.Header.appearance)
        } footer: {
            footnote(L10n.Ios.Settings.Appearance.languageHint)
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            HStack {
                label(L10n.Ios.Settings.About.version)
                Spacer()
                Text(AboutLinks.version)
                    .font(BanditoFont.mono(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
            }
            pageRow(L10n.Ios.Settings.About.website, AboutLinks.website)
            pageRow(L10n.Ios.Settings.About.docs, AboutLinks.docs)
            pageRow(L10n.Ios.Settings.About.report, AboutLinks.reportProblem)
            pageRow(L10n.Ios.Settings.About.privacy, AboutLinks.privacy)
            pageRow(L10n.Ios.Settings.About.terms, AboutLinks.terms)
        } header: {
            sectionHeader(L10n.Ios.Settings.Header.about)
        }
    }

    // MARK: Bindings and actions

    /// Turning the lock on checks the owner once; turning it off needs no check.
    private var faceIDBinding: Binding<Bool> {
        Binding(
            get: { settings.faceIDLock },
            set: { wantsOn in
                faceIDRefused = false
                guard wantsOn else {
                    settings.faceIDLock = false
                    return
                }
                Task {
                    if await biometrics.authenticate(reason: L10n.Ios.Settings.Security.enableReason) {
                        settings.faceIDLock = true
                    } else {
                        faceIDRefused = true
                    }
                }
            })
    }

    private var isConfirmingDisconnect: Binding<Bool> {
        Binding(
            get: { pendingDisconnect != nil },
            set: { if !$0 { pendingDisconnect = nil } })
    }

    private func refreshPermission() async {
        permission = await SystemNotifications.permission()
    }

    private func disconnect(_ server: ConnectedServer) {
        do {
            try servers.disconnect(server.id)
        } catch {
            disconnectFailed = true
        }
    }

    /// The system's own settings page for Bandito: notifications and the app's language live there.
    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Rows

    private func toggleRow(_ title: String, hint: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            labelStack(title, hint: hint)
        }
    }

    private func pageRow(_ title: String, _ url: URL) -> some View {
        Button {
            page = WebPage(url: url)
        } label: {
            HStack {
                label(title)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
    }

    private func labelStack(_ title: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title)
            if let hint {
                Text(hint)
                    .font(BanditoFont.text(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 15))
            .foregroundStyle(Color.Bandito.text)
    }

    private func actionLabel(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.display(size: 13.5, weight: 600))
            .foregroundStyle(Color.Bandito.signal)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.display(size: 10.5, weight: 600))
            .tracking(0.6)
            .foregroundStyle(Color.Bandito.text3)
    }

    private func footnote(_ text: String, danger: Bool = false) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 12))
            .foregroundStyle(danger ? Color.Bandito.danger : Color.Bandito.text3)
    }
}

/// One paired server: its name, a status dot with the word, and how this iPhone reaches it.
struct ConnectedServerRow: View {
    let server: ConnectedServer

    var body: some View {
        HStack(spacing: BanditoSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(BanditoFont.display(size: 13.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                HStack(spacing: BanditoSpace.s2) {
                    Circle()
                        .fill(server.isOnline ? Color.Bandito.ok : Color.Bandito.text3)
                        .frame(width: 7, height: 7)
                    Text(server.isOnline ? L10n.Server.Status.online : L10n.Server.Status.offline)
                        .font(BanditoFont.text(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            Spacer(minLength: BanditoSpace.s2)
            Text(server.transport.title)
                .font(BanditoFont.text(size: 12, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
        }
        .accessibilityElement(children: .combine)
    }
}

extension AppTheme {
    var title: String {
        switch self {
        case .system: L10n.Settings.Theme.system
        case .dark: L10n.Settings.Theme.dark
        case .light: L10n.Settings.Theme.light
        }
    }
}

extension MotionPreference {
    var title: String {
        switch self {
        case .system: L10n.Ios.Settings.Appearance.Motion.system
        case .always: L10n.Ios.Settings.Appearance.Motion.always
        }
    }
}

extension ServerTransport {
    var title: String {
        switch self {
        case .tailscale: L10n.Ios.Settings.Servers.Via.tailscale
        case .lan: L10n.Ios.Settings.Servers.Via.lan
        }
    }
}
