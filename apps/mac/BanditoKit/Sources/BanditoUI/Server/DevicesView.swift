import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server → Devices: the phones and Macs paired with this server. Revoke one, or pair a new one with a code and QR.
struct DevicesView: View {
    let server: ServerModel?
    @State private var devices: [Device] = []
    @State private var error: UserFacingMessage?
    @State private var revoking: Device?
    @State private var pairing = false

    var body: some View {
        ServerPage(
            title: L10n.Mode.serverDevices,
            trailing: {
                if let server, server.supports("pairing") {
                    Button(L10n.Devices.add) { pairing = true }
                        .banditoButton(.signal())
                        .fixedSize()
                }
            }
        ) {
            if let server, server.supports("pairing") {
                Text(L10n.Devices.intro)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                ServerCard {
                    if devices.isEmpty {
                        Text(L10n.Devices.empty)
                            .font(BanditoFont.text(size: 13, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                    }
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        deviceRow(device)
                            .padding(.vertical, 4)
                            // A line between rows only, not above the first one.
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
                                }
                            }
                    }
                    if let error {
                        UserFacingErrorView(message: error)
                    }
                }
            } else {
                ServerUnavailable(server: server)
            }
        }
        .task(id: server?.info != nil) {
            await reload()
        }
        .banditoSheet(isPresented: $pairing) {
            if let server {
                PairSheet(server: server)
            }
        }
        .confirmationDialog(
            L10n.Devices.revokeTitle(name: revoking?.name ?? ""),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible,
            presenting: revoking
        ) { device in
            Button(L10n.Devices.revoke, role: .destructive) {
                Task { await revoke(device) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Devices.revokeMessage)
        }
    }

    /// One paired device. This Mac is marked, and it cannot be revoked from itself.
    private func deviceRow(_ device: Device) -> some View {
        // Only the daemon's own word counts: a device named like this Mac is not necessarily this Mac.
        let isThisMac = device.current == true
        return HStack(spacing: 12) {
            Image(systemName: DeviceIcon.symbol(platform: device.platform, name: device.name))
                .font(.system(size: 15))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 30, height: 30)
                .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(BanditoFont.text(size: 13.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    if isThisMac {
                        Text(L10n.Server.Add.thisMac)
                            .font(BanditoFont.text(size: 11.5, weight: 500))
                            .foregroundStyle(Color.Bandito.signal)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Text(Self.detail(device))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Spacer(minLength: 8)
            if isThisMac {
                Button(L10n.Devices.revoke) {}
                    .banditoButton(.quiet())
                    .fixedSize()
                    .disabled(true)
                    .help(L10n.Devices.thisDeviceHint)
            } else {
                Button(L10n.Devices.revoke) { revoking = device }
                    .banditoButton(.quiet())
                    .fixedSize()
            }
        }
    }

    private func reload() async {
        guard let server, server.info != nil, server.supports("pairing") else { return }
        do {
            devices = try await server.devices()
            error = nil
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    private func revoke(_ device: Device) async {
        guard let server else { return }
        do {
            try await server.revokeDevice(device.id)
            await reload()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    static func detail(_ device: Device) -> String {
        let added = Date(timeIntervalSince1970: TimeInterval(device.createdAt) / 1000)
            .formatted(date: .abbreviated, time: .omitted)
        guard let seen = device.lastSeenAt else { return L10n.Devices.added(date: added) }
        let last = Date(timeIntervalSince1970: TimeInterval(seen) / 1000)
            .formatted(.relative(presentation: .named))
        return L10n.Devices.addedAndSeen(date: added, last: last)
    }
}

/// Makes a one-time code for a new device and shows it with the QR code the device scans.
private struct PairSheet: View {
    let server: ServerModel
    @Environment(\.dismiss) private var dismiss
    @State private var code: PairCode?
    @State private var error: UserFacingMessage?

    var body: some View {
        VStack(spacing: 18) {
            Text(L10n.Devices.pairTitle)
                .font(BanditoFont.display(size: 15.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Devices.pairIntro)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            if let code {
                Text(code.code)
                    .font(BanditoFont.mono(size: 26, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .textSelection(.enabled)
                QRCodeView(text: PairLink.url(code: code.code, host: host))
                Text(L10n.Devices.pairExpires(minutes: String(code.expiresInMs / 60_000)))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            } else if let error {
                UserFacingErrorView(message: error)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 120)
            }
            HStack {
                Spacer()
                Button(L10n.Common.close) { dismiss() }
                    .banditoButton(.quiet())
            }
        }
        .padding(26)
        .frame(width: 420)
        .background(Color.Bandito.surface2)
        .task {
            do {
                code = try await server.createPairCode()
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    /// The address the new device connects to: the server's host and port, or this Mac's name for a local server.
    private var host: String {
        switch server.config.endpoint {
        case .webSocket(let url):
            let port = url.port.map { ":\($0)" } ?? ""
            return (url.host ?? "") + port
        case .local:
            return server.info?.hostname ?? ""
        case .ssh(let target, _):
            // The new device reaches the server over SSH too: the target is what it needs.
            return target
        }
    }
}
