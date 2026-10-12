import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The place above the sidebar footer where one update shows up: the app's own, or a server's daemon update (see
/// `UpdateBannerRule`, one at a time). Empty (and zero high) while there is nothing to say; otherwise the banner slides
/// up from the bottom and fades in, or only fades with Reduce Motion.
struct UpdateBannerSlot: View {
    @Environment(AppUpdateCenter.self) private var center: AppUpdateCenter?
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The × of the server banner, kept in state so that a dismiss redraws the slot.
    @State private var dismissals = ServerUpdateDismissals.load()

    var body: some View {
        let phase = center?.phase ?? .idle
        let choice = UpdateBannerRule.choose(
            appVisible: AppUpdateRules.isVisible(phase),
            servers: app.serverUpdateCandidates, selected: app.currentServer?.id,
            isDismissed: { dismissals.isDismissed(server: $0, version: $1) })
        VStack(spacing: 0) {
            if choice != .none {
                card(choice, phase: phase)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .banditoAnimation(.spring(response: 0.42, dampingFraction: 0.86), value: choice)
    }

    @ViewBuilder
    private func card(_ choice: UpdateBannerChoice, phase: AppUpdateCenter.Phase) -> some View {
        switch choice {
        case .none:
            EmptyView()
        case .app:
            if let center {
                UpdateBanner(phase: phase, center: center)
            }
        case .server(let id, _):
            if let server = app.servers.first(where: { $0.id == id }), let shown = app.daemonOffer(for: server) {
                ServerUpdateBanner(
                    serverName: ServerPicker.name(server), offer: shown.offer, isLive: shown.isLive,
                    phase: app.daemonUpdate.phase,
                    onInstall: { app.askDaemonUpdate(server, offer: shown.offer) },
                    onDismiss: { dismissals.dismiss(server: id, version: shown.offer.latest) })
            }
        }
    }
}

/// The card: a round badge, what is going on, and what the person can do about it.
struct UpdateBanner: View {
    let phase: AppUpdateCenter.Phase
    let center: AppUpdateCenter

    @Environment(\.openURL) private var openURL

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    static let badgeSize: CGFloat = 28
    private static let gap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Self.gap) {
                UpdateBadge(phase: phase)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppUpdateRules.title(for: phase) ?? "")
                        .font(BanditoFont.text(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = AppUpdateRules.subtitle(for: phase) {
                        Text(subtitle)
                            .font(BanditoFont.text(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            // A long reason is cut at two lines; the tooltip has all of it.
                            .help(subtitle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if AppUpdateRules.canDismiss(phase) {
                    Button {
                        center.dismiss()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .banditoButton(.icon(size: 24, label: closeLabel))
                    .focusable(false)
                }
            }
            // Under the whole row, indented past the badge: the text column is too narrow for two buttons.
            detail
                .padding(.leading, Self.badgeSize + Self.gap)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.signal.opacity(0.08), in: Self.shape)
        .overlay(Self.shape.strokeBorder(Color.Bandito.signal.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .banditoAnimation(.easeInOut(duration: BanditoMotion.base), value: AppUpdateRules.layoutKey(phase))
    }

    private var closeLabel: String {
        if case .available = phase { return L10n.AppUpdate.later }
        return L10n.AppUpdate.close
    }

    /// The part under the words: the buttons of an offer, the bar of a download, the retry of a failure.
    @ViewBuilder
    private var detail: some View {
        switch phase {
        case .available:
            HStack(spacing: 12) {
                Button(L10n.AppUpdate.install) { center.install() }
                    .banditoButton(.signal(size: .compact))
                if let url = AppUpdateRules.releaseNotesURL(for: phase) {
                    Button {
                        openURL(url)
                    } label: {
                        Text(L10n.AppUpdate.whatsNew)
                            .font(BanditoFont.text(size: 12, weight: 500))
                            .foregroundStyle(Color.Bandito.text2)
                            .lineLimit(1)
                    }
                    .banditoButton(.link)
                    .fixedSize()
                }
            }
            .padding(.top, 8)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                UpdateProgressBar(fraction: fraction)
                if let text = AppUpdateRules.percentText(fraction) {
                    Text(text)
                        .font(BanditoFont.text(size: 11.5, weight: 500))
                        .monospacedDigit()
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.top, 6)
        case .failed:
            Button(L10n.AppUpdate.retry) { center.check() }
                .banditoButton(.quiet(size: .compact))
                .padding(.top, 8)
        case .idle, .checking, .preparing, .installing, .upToDate:
            EmptyView()
        }
    }
}

/// The round badge at the left: a symbol in the phase's tone, or a spinner while the app waits.
private struct UpdateBadge: View {
    let phase: AppUpdateCenter.Phase

    private var tone: Color {
        switch phase {
        case .upToDate: Color.Bandito.ok
        case .failed: Color.Bandito.danger
        default: Color.Bandito.signal
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(tone.opacity(0.12))
            if AppUpdateRules.showsSpinner(phase) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: AppUpdateRules.symbol(for: phase))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tone)
            }
        }
        .frame(width: UpdateBanner.badgeSize, height: UpdateBanner.badgeSize)
        .accessibilityHidden(true)
    }
}

/// A 4 pt bar. With a share it fills to it (one step per whole percent); without one a short piece runs along the
/// track, and stands still in the middle when motion is off or the window is not in front.
private struct UpdateProgressBar: View {
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    private var moves: Bool {
        !reduceMotion && MotionLevel(stored: motionLevel).allowsRepeatingMotion && controlActiveState == .active
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Bandito.text.opacity(0.08))
                if let fraction {
                    Capsule()
                        .fill(Color.Bandito.text)
                        .frame(width: width * min(max(fraction, 0), 1))
                        .banditoAnimation(.easeOut(duration: BanditoMotion.base), value: AppUpdateRules.percent(fraction))
                } else {
                    let piece = width * 0.35
                    PhaseAnimator(moves ? [CGFloat(0), CGFloat(1)] : [CGFloat(0.5)]) { position in
                        Capsule()
                            .fill(Color.Bandito.text)
                            .frame(width: piece)
                            .offset(x: (width - piece) * position)
                    } animation: { _ in
                        .easeInOut(duration: 0.9)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(AppUpdateRules.percentText(fraction) ?? "")
    }
}
