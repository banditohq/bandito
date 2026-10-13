import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// «Через облако Bandito» on a server's iPhone settings: the recommended way, first in the block. One switch turns it
/// on (registers the server through the account and hands it to the daemon) or off (daemon forgets it, registration is
/// deleted). The state under it says what is going on in words.
struct CloudAccessBlock: View {
    let cloud: RelayController?
    /// A state to show without a controller (the layout audit).
    var preview: CloudAccessRules.Status?
    let onSignIn: () -> Void

    private var status: CloudAccessRules.Status {
        if let preview { return preview }
        guard let cloud else { return .off }
        return CloudAccessRules.status(phase: cloud.phase, relay: cloud.status, problem: cloud.problem)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusRow
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.Bandito.signal)
                .frame(width: 34, height: 34)
                .background(Color.Bandito.signal.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L10n.ServerSettings.Phone.Cloud.title)
                        .font(BanditoFont.text(size: 13.5, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.ServerSettings.Phone.Cloud.badge)
                        .font(BanditoFont.text(size: 10.5, weight: 600))
                        .foregroundStyle(Color.Bandito.signal)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.Bandito.signal.opacity(0.14), in: Capsule())
                }
                Text(L10n.ServerSettings.Phone.Cloud.hint)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: switchBinding)
                .labelsHidden()
                .toggleStyle(BanditoToggleStyle())
                .disabled(cloud == nil || cloud?.isBusy == true)
                .accessibilityLabel(L10n.ServerSettings.Phone.Cloud.title)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var switchBinding: Binding<Bool> {
        Binding(
            get: {
                if let preview { return preview != .off }
                guard let cloud else { return false }
                return CloudAccessRules.switchIsOn(phase: cloud.phase, relay: cloud.status, problem: cloud.problem)
            },
            set: { on in
                guard let cloud else { return }
                Task { if on { await cloud.enable() } else { await cloud.disable() } }
            })
    }

    @ViewBuilder private var statusRow: some View {
        switch status {
        case .off:
            EmptyView()
        case .enabling:
            busy(L10n.ServerSettings.Phone.Cloud.enabling)
        case .connecting:
            busy(L10n.ServerSettings.Phone.Cloud.connecting)
        case .disabling:
            busy(L10n.ServerSettings.Phone.Cloud.disabling)
        case .connected:
            line(L10n.ServerSettings.Phone.Cloud.connected, color: Color.Bandito.ok, dot: true)
        case .waiting(let reason):
            if let reason, !reason.isEmpty {
                line(L10n.ServerSettings.Phone.Cloud.waitingReason(reason: reason), color: Color.Bandito.text2, dot: false)
            } else {
                line(L10n.ServerSettings.Phone.Cloud.waiting, color: Color.Bandito.text2, dot: false)
            }
        case .signIn:
            HStack(spacing: 12) {
                Text(L10n.ServerSettings.Phone.Cloud.signIn)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.ServerSettings.Phone.Cloud.signInAction, action: onSignIn)
                    .banditoButton(.signal())
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        case .unsupported:
            line(L10n.ServerSettings.Phone.Cloud.unsupported, color: Color.Bandito.text2, dot: false)
        case .tooMany:
            line(L10n.ServerSettings.Phone.Cloud.tooMany, color: Color.Bandito.danger, dot: false)
        case .failed(let message):
            line(message.text, color: Color.Bandito.danger, dot: false)
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func line(_ text: String, color: Color, dot: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if dot {
                Circle().fill(color).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            }
            Text(text)
                .font(BanditoFont.text(size: 12, weight: dot ? 500 : 400))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

/// Tailscale was asked for and the server has none: two steps with the commands to copy, and a way to look again.
/// The daemon cannot install Tailscale itself (it is not one of the components of `setup.install`), so the command is
/// the person's to run on the server.
struct TailscaleHelper: View {
    let os: String?
    let onRecheck: () -> Void
    var onUseCloud: (() -> Void)?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Bandito.signal)
                Text(L10n.ServerSettings.Phone.Tailscale.title)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.ServerSettings.Phone.Tailscale.body)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            step(title: L10n.ServerSettings.Phone.Tailscale.step1) {
                switch CloudAccessRules.install(os: os) {
                case .command(let command):
                    Text(L10n.ServerSettings.Phone.Tailscale.installLinux)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    commandBox(command)
                case .app(let url):
                    Text(L10n.ServerSettings.Phone.Tailscale.installMac)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.ServerSettings.Phone.Tailscale.download) { SystemActions.open(url) }
                        .banditoButton(.quiet())
                        .fixedSize()
                }
            }
            step(title: L10n.ServerSettings.Phone.Tailscale.step2) {
                Text(L10n.ServerSettings.Phone.Tailscale.login)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
                commandBox(CloudAccessRules.loginCommand)
            }
            HStack(spacing: 10) {
                Button(L10n.ServerSettings.Phone.Tailscale.recheck, action: onRecheck)
                    .banditoButton(.signal())
                    .fixedSize()
            }
            if let onUseCloud {
                Button(action: onUseCloud) {
                    Text(L10n.ServerSettings.Phone.Tailscale.orCloud)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .banditoButton(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.Bandito.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func step(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BanditoFont.text(size: 12.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            content()
        }
    }

    private func commandBox(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(BanditoFont.mono(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == command ? L10n.ServerSettings.Phone.Tailscale.copied : L10n.ServerSettings.Phone.Tailscale.copy) {
                SystemActions.copy(command)
                copied = command
            }
            .banditoButton(.quiet())
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.Bandito.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
