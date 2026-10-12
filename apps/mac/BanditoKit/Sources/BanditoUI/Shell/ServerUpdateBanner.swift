import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The sidebar card for a server's daemon update, under the app's own banner's place. It says which server and version,
/// and installs with the same button, progress and failure as Server → Overview: the install goes through the app's
/// confirmation (`AppModel.askDaemonUpdate`), so both paths are one.
struct ServerUpdateBanner: View {
    /// The server's name, as the server menu shows it.
    let serverName: String
    /// The release the server offers, or the one the last update installed (then `isLive` is false).
    let offer: DaemonUpdate
    let isLive: Bool
    let phase: DaemonUpdateModel.Phase
    let onInstall: () -> Void
    let onDismiss: () -> Void

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    private static let badgeSize: CGFloat = 28
    private static let gap: CGFloat = 10

    private var isBusy: Bool { phase == .updating || phase == .restarting }

    private var status: String? { DaemonUpdateModel.statusText(for: phase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Self.gap) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(isLive ? L10n.ServerUpdate.Banner.title(name: serverName, version: offer.latest) : (status ?? ""))
                        .font(BanditoFont.text(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // The title of an outcome says what happened, not on which server: the name goes under it.
                    if !isLive {
                        Text(serverName)
                            .font(BanditoFont.text(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !isBusy {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .banditoButton(.icon(size: 24, label: L10n.AppUpdate.close))
                    .focusable(false)
                }
            }
            detail
                .padding(.leading, Self.badgeSize + Self.gap)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.08), in: Self.shape)
        .overlay(Self.shape.strokeBorder(tone.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// While the update runs, its status; then the button of a live offer (again after a failure); then the failure of a
    /// live offer. The outcome's words are the title already, so nothing more is said for it.
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBusy, let status {
                Text(status)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLive, !isBusy {
                Button(L10n.Server.DaemonUpdate.button, action: onInstall)
                    .banditoButton(.signal(size: .compact))
            }
            if isLive, case .failed(let failure) = phase {
                UserFacingErrorView(message: failure.wrapped { L10n.Server.DaemonUpdate.failed(error: $0) })
            }
        }
    }

    private var tone: Color {
        switch phase {
        case .done, .manualRestart: Color.Bandito.ok
        case .failed, .timedOut: Color.Bandito.danger
        default: Color.Bandito.signal
        }
    }

    private var badge: some View {
        ZStack {
            Circle().fill(tone.opacity(0.12))
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tone)
            }
        }
        .frame(width: Self.badgeSize, height: Self.badgeSize)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch phase {
        case .done: "checkmark"
        case .failed, .timedOut: "exclamationmark.triangle"
        default: "arrow.up"
        }
    }
}
