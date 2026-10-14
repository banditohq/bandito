import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings of one server → iPhone: the switch for access from a phone (Off / Via Tailscale / On the local network)
/// with what each choice risks, the button that pairs an iPhone with a QR code, and the devices paired with the server
/// (each can be disconnected). Needs the `phone_access` feature; an older server says so.
struct ServerPhoneSection: View {
    let server: ServerModel
    let model: ServerSettingsModel
    /// Devices to show without asking the server (the layout audit); nil on a live page.
    let previewDevices: [Device]?
    /// The cloud state to show without a controller (the layout audit); nil on a live page.
    let previewCloud: CloudAccessRules.Status?
    @State private var devices: [Device]
    @State private var devicesFailed = false
    @State private var disconnecting: Device?
    @State private var pairing = false
    @State private var cloud: RelayController?
    @Environment(AccountHub.self) private var hub
    @Environment(Router.self) private var router

    var body: some View {
        SettingsGroup(title: L10n.ServerSettings.Phone.title) {
            if !server.supports("phone_access") {
                Text(L10n.ServerSettings.Phone.unsupported)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            } else if let settings = model.snapshot?.settings {
                if server.supportsRelay {
                    CloudAccessBlock(cloud: cloud, preview: previewCloud, onSignIn: signIn, onChanged: { hub.requestAccessCycle() })
                    Divider().padding(.horizontal, 16)
                    SectionLabel(L10n.ServerSettings.Phone.Direct.title)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                accessRows(settings)
                Divider().padding(.horizontal, 16)
                connectRow(settings)
                Divider().padding(.horizontal, 16)
                devicesBlock
            }
        }
        .task(id: DevicesKey(connected: server.info != nil, revision: server.settingsRevision)) {
            await reloadDevices()
        }
        .task(id: RelayKey(connected: server.info != nil, revision: server.relayRevision)) {
            await refreshCloud()
        }
        .banditoSheet(isPresented: $pairing) {
            PhonePairSheet(server: server)
        }
        .onChange(of: pairing) { _, open in
            // A phone paired while the sheet was open: show it in the list.
            if !open { Task { await reloadDevices() } }
        }
        .confirmationDialog(
            L10n.ServerSettings.Phone.Devices.disconnectTitle(name: disconnecting?.name ?? ""),
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible,
            presenting: disconnecting
        ) { device in
            Button(L10n.ServerSettings.Phone.Devices.disconnect, role: .destructive) {
                Task { await disconnect(device) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.ServerSettings.Phone.Devices.disconnectMessage)
        }
    }

    init(
        server: ServerModel, model: ServerSettingsModel, previewDevices: [Device]? = nil,
        previewCloud: CloudAccessRules.Status? = nil
    ) {
        self.server = server
        self.model = model
        self.previewDevices = previewDevices
        self.previewCloud = previewCloud
        _devices = State(initialValue: previewDevices ?? [])
    }

    private struct DevicesKey: Hashable {
        let connected: Bool
        let revision: Int
    }

    private struct RelayKey: Hashable {
        let connected: Bool
        let revision: Int
    }


    private func refreshCloud() async {
        guard previewDevices == nil, server.info != nil, server.supportsRelay else { return }
        if cloud == nil {
            let hub = hub
            cloud = RelayController(
                host: server,
                registrar: { [hub] in
                    guard await hub.signedIn else { return nil }
                    return try await hub.prepare()
                })
        }
        await cloud?.refresh()
    }

    private func signIn() {
        SettingsHandoff.openMainWindow(router: router) { $0.sheet = .account }
    }

    // MARK: Access

    private func accessRows(_ settings: ServerSettingValues) -> some View {
        VStack(spacing: 0) {
            SettingsRow(title: L10n.ServerSettings.Phone.Access.title, hint: L10n.ServerSettings.Phone.Access.hint) {
                SegmentedPicker(
                    selection: Binding(
                        get: { settings.phoneAccess },
                        set: { mode in change(.phoneAccess(mode)) }),
                    options: PhoneAccessRules.options
                )
                .fixedSize()
            }
            note(
                PhoneAccessRules.risk(for: settings.phoneAccess),
                color: PhoneAccessRules.isWarning(settings.phoneAccess) ? Color.Bandito.text : Color.Bandito.text3)
            statusLine(settings)
            fingerprintRow
        }
    }

    /// The certificate's fingerprint, to compare with what an iPhone shows when it is paired by a typed address.
    @ViewBuilder private var fingerprintRow: some View {
        if let fingerprint = model.snapshot?.phone?.tlsFingerprint {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.ServerSettings.Phone.Fingerprint.title)
                    .font(BanditoFont.text(size: 12, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                Text(PinnedFingerprint.display(fingerprint))
                    .font(BanditoFont.mono(size: 10.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.ServerSettings.Phone.Fingerprint.hint)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private func statusLine(_ settings: ServerSettingValues) -> some View {
        switch PhoneAccessRules.line(mode: settings.phoneAccess, status: model.snapshot?.phone) {
        case .none:
            EmptyView()
        case .listening(let addresses):
            note(L10n.ServerSettings.Phone.listening(addresses: addresses), color: Color.Bandito.ok, mono: true)
        case .notListening:
            note(L10n.ServerSettings.Phone.notListening, color: Color.Bandito.text3)
        case .failed(let reason):
            if CloudAccessRules.showsTailscaleHelper(mode: settings.phoneAccess, status: model.snapshot?.phone) {
                TailscaleHelper(
                    os: server.info?.os, onRecheck: { Task { await model.recheckPhoneAccess() } },
                    onUseCloud: cloudAction)
            } else {
                note(L10n.ServerSettings.Phone.error(reason: reason), color: Color.Bandito.danger)
            }
        }
    }

    /// The Tailscale helper's way to the cloud, when the server can use it: the same as the switch, so the iPhone block
    /// stays on.
    private var cloudAction: (() -> Void)? {
        guard server.supportsRelay, let cloud else { return nil }
        return {
            PhoneAccessRules.turnOnIPhoneBlock()
            Task { await cloud.enable() }
        }
    }

    private func note(_ text: String, color: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? BanditoFont.mono(size: 11.5, weight: 400) : BanditoFont.text(size: 12, weight: 400))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
    }

    // MARK: Connect

    private func connectRow(_ settings: ServerSettingValues) -> some View {
        let can = PhoneAccessRules.canConnect(
            mode: settings.phoneAccess, status: model.snapshot?.phone, cloudConnected: cloud?.isConnected == true)
        return SettingsRow(
            title: L10n.ServerSettings.Phone.Connect.title,
            hint: settings.phoneAccess == .off
                ? L10n.ServerSettings.Phone.Connect.needsAccess : L10n.ServerSettings.Phone.Connect.hint
        ) {
            Button(L10n.ServerSettings.Phone.Connect.title) { pairing = true }
                .banditoButton(.signal())
                .fixedSize()
                .disabled(!can)
        }
    }

    // MARK: Devices

    private var devicesBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.ServerSettings.Phone.Devices.title)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            if devicesFailed {
                note(L10n.ServerSettings.Phone.Devices.loadFailed, color: Color.Bandito.danger)
            } else if devices.isEmpty {
                note(L10n.ServerSettings.Phone.Devices.empty, color: Color.Bandito.text3)
            }
            ForEach(devices) { device in
                deviceRow(device)
            }
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        // Only the daemon's own word counts: a device named like this Mac is not necessarily this Mac.
        let isThisMac = device.current == true
        return HStack(spacing: 12) {
            Image(systemName: DeviceIcon.symbol(platform: device.platform, name: device.name))
                .font(.system(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 28, height: 28)
                .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(DevicesView.detail(device))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.ServerSettings.Phone.Devices.disconnect) { disconnecting = device }
                .banditoButton(.quiet())
                .fixedSize()
                .disabled(isThisMac)
                .help(isThisMac ? L10n.Devices.thisDeviceHint : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func reloadDevices() async {
        guard previewDevices == nil, server.info != nil, server.supports("phone_access"), server.supports("pairing")
        else { return }
        do {
            let list = try await server.devices()
            if list != devices { devices = list }
            if devicesFailed { devicesFailed = false }
        } catch {
            if !devicesFailed { devicesFailed = true }
        }
    }

    private func disconnect(_ device: Device) async {
        do {
            try await server.revokeDevice(device.id)
            await reloadDevices()
        } catch {
            devicesFailed = true
        }
    }

    private func change(_ change: ServerSettingChange) {
        Task { await model.apply(change) }
    }
}
