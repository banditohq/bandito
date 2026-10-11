import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Shows the code sign-in in progress over whatever mode is in front: the code, the button that opens the provider's
/// page, the wait, then "Connected". It is driven by `DeviceSignIn.phase` alone; closing it gives the sign-in up.
struct DeviceSignInPresenter: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let device = app.device
        content.banditoSheet(
            isPresented: Binding(
                get: { device.isActive },
                set: { shown in if !shown { Task { await device.dismiss() } } }),
            dismissOnOutsideClick: false
        ) {
            DeviceSignInSheet(device: device)
        }
    }
}

struct DeviceSignInSheet: View {
    let device: DeviceSignIn

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(BanditoFont.display(size: 18.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)
            content
            buttons
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .background(Color.Bandito.surface2)
    }

    private var name: String {
        switch device.phase {
        case .idle: ""
        case .starting(let name): name
        case .waiting(let name, _, _, _): name
        case .connected(let name, _): name
        case .failed(let name, _, _): name
        }
    }

    private var title: String {
        name.isEmpty ? L10n.Integrations.connect : L10n.Integrations.Oauth.title(name: name)
    }

    @ViewBuilder
    private var content: some View {
        switch device.phase {
        case .idle:
            EmptyView()
        case .starting:
            progress(L10n.Integrations.Device.starting)
        case .waiting(_, let code, let page, let expiresAt):
            DeviceCodeBlock(code: code, page: page, expiresAt: expiresAt, copied: device.copied, copy: device.copyCode)
        case .connected:
            Label {
                Text(L10n.Integrations.Oauth.connected)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(BanditoFont.text(size: 13.5, weight: 500))
            .foregroundStyle(Color.Bandito.ok)
        case .failed(_, let message, _):
            UserFacingErrorView(message: message)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(BanditoFont.text(size: 13.5, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            switch device.phase {
            case .idle:
                EmptyView()
            case .starting:
                Button(L10n.Common.cancel) { Task { await device.dismiss() } }
                    .banditoButton(.quiet())
                    .keyboardShortcut(.cancelAction)
            case .waiting(_, _, let page, _):
                Button(L10n.Common.cancel) { Task { await device.dismiss() } }
                    .banditoButton(.quiet())
                    .keyboardShortcut(.cancelAction)
                Button(L10n.Integrations.Device.open(address: page.address)) { device.openPage() }
                    .banditoButton(.signal())
                    .keyboardShortcut(.defaultAction)
            case .connected:
                Button(L10n.Integrations.Oauth.done) { Task { await device.dismiss() } }
                    .banditoButton(.signal())
                    .keyboardShortcut(.defaultAction)
            case .failed(_, _, let canRetry):
                Button(L10n.Common.close) { Task { await device.dismiss() } }
                    .banditoButton(.quiet())
                    .keyboardShortcut(.cancelAction)
                if canRetry {
                    Button(L10n.Integrations.Oauth.retry) { Task { await device.retry() } }
                        .banditoButton(.signal())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// The code in large type, Copy, the wait and the countdown. The countdown is a `TimelineView`, so it ticks without
/// writing any state.
private struct DeviceCodeBlock: View {
    let code: String
    let page: DevicePage
    let expiresAt: Date
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Integrations.Device.codeHint(site: page.host))
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
            codeRow
            waitRow
        }
    }

    private var codeRow: some View {
        HStack(spacing: 12) {
            Text(UserCodeFormat.grouped(code))
                .font(BanditoFont.mono(size: 34, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .tracking(3)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Button(L10n.Integrations.Device.copy, action: copy)
                    .banditoButton(.quiet())
                    .fixedSize()
                if copied {
                    Text(L10n.Integrations.Device.copied)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
        }
    }

    private var waitRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L10n.Integrations.Device.waiting(site: page.host))
                    .font(BanditoFont.text(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = deviceSecondsLeft(expiresAt: Int64(expiresAt.timeIntervalSince1970 * 1000), now: context.date)
                Text(L10n.Integrations.Device.expiresIn(time: deviceCountdown(seconds: left)))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .monospacedDigit()
            }
        }
    }
}
