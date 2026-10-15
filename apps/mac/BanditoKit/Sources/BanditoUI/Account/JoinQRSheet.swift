import BanditoDesign
import BanditoKit
import BanditoL10n
import CryptoKit
import SwiftUI

/// What `.sheet(item:)` opens: one value is one sheet, so a second click makes a second, fresh model.
struct JoinQRRequest: Identifiable {
    let id = UUID()
}

/// Builds the model of the join sheet from the account of this Mac.
@MainActor
enum JoinQRFactory {
    /// Reads this Mac's keys (made on first use) and makes the model. Throws what `AccountHub.prepare` throws.
    static func make(hub: AccountHub, onFinished: @escaping @MainActor () -> Void) async throws -> JoinQRModel {
        let client = try await hub.prepare()
        guard let identity = hub.identity,
            let raw = Data(base64Encoded: identity.publicKeyBase64),
            let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        else { throw AccountHubError.notReady }
        return JoinQRModel(
            backend: AccountJoinBackend(client: client, identity: identity),
            macPublicKey: publicKey, macName: DeviceDescriptor.current.name,
            blocker: { [weak hub] in await blocker(of: hub) },
            syncKey: { [weak hub] in hub.flatMap { try? SyncKey.load(from: $0.keys) } },
            onApproved: { [weak hub] in await hub?.deviceApproved() },
            onFinished: onFinished)
    }

    /// Whether this Mac can let a new device in: signed in, approved, and holding the sync key. The account is read
    /// again first, so an approval that happened a minute ago counts.
    static func blocker(of hub: AccountHub?) async -> JoinQRBlocker? {
        guard let hub, hub.signedIn else { return .signedOut }
        if let result = try? await hub.inspect() {
            switch result.route {
            case .waitForApproval: return .notApproved
            case .recoverRequired: return .noSyncKey
            case .firstDevice, .ready: break
            }
        } else if let me = hub.me, !me.device.approved {
            // Offline: what was read last. Without any answer the cloud's own error shows when the ticket is made.
            return .notApproved
        }
        return hub.hasSyncKey ? nil : .noSyncKey
    }
}

/// «Добавить iPhone или iPad»: the sheet with the join QR code (profile → Devices).
struct JoinQRSheet: View {
    @Environment(AccountHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: JoinQRModel?
    @State private var setupError: UserFacingMessage?
    /// A model to show without asking anybody (the layout audit and the screenshots).
    var preview: JoinQRModel?

    private var shown: JoinQRModel? { preview ?? model }

    var body: some View {
        VStack(spacing: 18) {
            Text(L10n.JoinQR.title)
                .font(BanditoFont.display(size: 15.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let shown {
                    JoinQRContent(model: shown)
                } else if let setupError {
                    UserFacingErrorView(message: setupError)
                } else {
                    ProgressView().controlSize(.regular).frame(maxWidth: .infinity, minHeight: 150)
                }
            }
            .animation(reduceMotion ? nil : BanditoMotion.ease, value: shown?.phase)
            ActionRow {
                if let shown {
                    JoinQRButtons(model: shown, close: { dismiss() })
                } else {
                    Button(L10n.Common.close) { dismiss() }
                        .banditoButton(.quiet())
                        .fixedSize()
                }
            }
        }
        .padding(26)
        .frame(width: 420)
        .background(Color.Bandito.surface2)
        .task { await begin() }
        .onDisappear { model?.close() }
    }

    private func begin() async {
        guard preview == nil, model == nil else { return }
        let close = dismiss
        do {
            let made = try await JoinQRFactory.make(hub: hub, onFinished: { close() })
            model = made
            made.start()
        } catch {
            setupError = SignInMessages.setupText(for: error)
        }
    }
}

/// What the sheet and the wizard show for the model's phase.
struct JoinQRContent: View {
    let model: JoinQRModel
    var qrSize: CGFloat = 200

    var body: some View {
        switch model.phase {
        case .preparing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                text(L10n.PhoneWizard.preparing)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
        case .blocked(let reason):
            problem(blocked(reason), symbol: "exclamationmark.triangle", color: Color.Bandito.text3)
        case .showing(let link, let expiresAt):
            VStack(spacing: 14) {
                text(L10n.JoinQR.steps)
                QRCodeView(text: link, size: qrSize)
                    .accessibilityLabel(L10n.JoinQR.qrLabel)
                JoinCountdown(expiresAt: expiresAt)
                waiting(L10n.JoinQR.waiting)
            }
        case .claiming(let name, let retrying):
            VStack(spacing: 12) {
                waiting(L10n.JoinQR.claiming(name: name ?? "iPhone"))
                if retrying {
                    Text(L10n.JoinQR.retrying)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
        case .added(let name):
            VStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.Bandito.bg)
                    .frame(width: 56, height: 56)
                    .background(Color.Bandito.ok, in: Circle())
                    .accessibilityHidden(true)
                Text(L10n.JoinQR.added(name: name))
                    .font(BanditoFont.display(size: 14.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                text(L10n.JoinQR.addedHint)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
        case .failed(let message):
            UserFacingErrorView(message: message)
        case .badProof(let removed):
            problem(
                removed ? L10n.JoinQR.badProof : L10n.JoinQR.badProofKept, symbol: "xmark.shield",
                color: Color.Bandito.danger, danger: true)
        case .expired:
            problem(L10n.JoinQR.expired, symbol: "clock", color: Color.Bandito.text3)
        }
    }

    private func blocked(_ reason: JoinQRBlocker) -> String {
        switch reason {
        case .signedOut: L10n.JoinQR.Blocked.signedOut
        case .notApproved: L10n.JoinQR.Blocked.notApproved
        case .noSyncKey: L10n.JoinQR.Blocked.noKey
        }
    }

    private func problem(_ message: String, symbol: String, color: Color, danger: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(message)
                .font(BanditoFont.text(size: 13, weight: danger ? 500 : 400))
                .foregroundStyle(danger ? Color.Bandito.danger : Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .font(BanditoFont.text(size: 13, weight: 400))
            .foregroundStyle(Color.Bandito.text2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func waiting(_ string: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(string)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "The code works for 4:32 more". One text that the clock redraws once a second.
private struct JoinCountdown: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(L10n.JoinQR.expiresIn(time: Self.format(expiresAt.timeIntervalSince(context.date))))
                .font(BanditoFont.text(size: 12, weight: 400))
                .monospacedDigit()
                .foregroundStyle(Color.Bandito.text3)
        }
    }

    /// `m:ss`, never negative.
    static func format(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return "\(whole / 60):" + (whole % 60 < 10 ? "0" : "") + "\(whole % 60)"
    }
}

/// The buttons under the model's phase: a new code where the code is gone, "Done" when the iPhone is in, Close.
struct JoinQRButtons: View {
    let model: JoinQRModel
    let close: () -> Void

    var body: some View {
        switch model.phase {
        case .failed, .expired, .badProof:
            Button(L10n.JoinQR.new) { model.newCode() }
                .banditoButton(.signal())
                .fixedSize()
            Button(L10n.Common.close, action: close)
                .banditoButton(.quiet())
                .fixedSize()
        case .added:
            Button(L10n.PhoneWizard.Done.action, action: close)
                .banditoButton(.signal())
                .fixedSize()
        case .showing:
            Button(L10n.JoinQR.new) { model.newCode() }
                .banditoButton(.quiet())
                .fixedSize()
            Button(L10n.Common.close, action: close)
                .banditoButton(.quiet())
                .fixedSize()
        case .preparing, .blocked, .claiming:
            Button(L10n.Common.close, action: close)
                .banditoButton(.quiet())
                .fixedSize()
        }
    }
}
