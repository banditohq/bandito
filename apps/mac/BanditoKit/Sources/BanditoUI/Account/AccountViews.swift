import BanditoDesign
import BanditoKit
import BanditoL10n
import CryptoKit
import SwiftUI

/// The code of this Mac, large and monospaced, for the other device to compare.
struct DeviceCodeText: View {
    var code: String

    var body: some View {
        Text(code)
            .font(BanditoFont.font(size: 30, weight: 600, mono: true))
            .foregroundStyle(Color.Bandito.text)
            .tracking(2)
            .textSelection(.enabled)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.Bandito.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.Bandito.text.opacity(0.1)))
    }
}

/// "Reset the account" confirmation: the person types RESET, then the action runs.
struct ResetConfirmation: View {
    var onConfirm: () async throws -> Void
    /// "Cancel": nothing is reset, the screen goes back.
    var onCancel: (() -> Void)?
    /// Shown with a too-old session: the reset needs a fresh sign-in.
    var onSignInAgain: (() -> Void)?

    @State private var typed = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var sessionTooOld = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Onboarding.Account.resetWarning)
                .font(BanditoFont.font(size: 13.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            HStack(spacing: 8) {
                TextField(L10n.Onboarding.Account.resetWordHint, text: $typed)
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 14, weight: 400, mono: true))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 200)
                Button(L10n.Onboarding.Account.resetAction) {
                    Task { await run() }
                }
                .buttonStyle(SignalButtonStyle())
                .disabled(typed != "RESET" || busy)
                if let onCancel {
                    Button(L10n.Common.cancel, action: onCancel)
                        .buttonStyle(QuietButtonStyle())
                        .disabled(busy)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            if sessionTooOld, let onSignInAgain {
                Button(L10n.Onboarding.Account.signInAgain, action: onSignInAgain)
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private func run() async {
        busy = true
        defer { busy = false }
        do {
            try await onConfirm()
        } catch AccountError.api(code: "session_too_old", status: _) {
            sessionTooOld = true
            errorText = SignInMessages.text(for: AccountError.api(code: "session_too_old", status: 403))
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }
}

/// Step 3 of 5 for a device that is not approved yet, and the recovery path for an account whose key is lost.
struct DeviceApprovalStep: View {
    /// The device is approved and holds the key: go on.
    var onFinished: () -> Void
    /// Signing out: back to the sign-in step.
    var onNoAccess: () -> Void

    @Environment(AccountHub.self) private var hub
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var mode: Mode = .loading
    @State private var model: DeviceApprovalModel?
    @State private var errorText: String?
    @State private var refuseFailed = false

    private enum Mode: Equatable {
        case loading
        case waiting
        case confirmSender
        case recover
        case refused
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch mode {
            case .loading:
                ProgressView().controlSize(.small)
            case .waiting:
                waiting
            case .confirmSender:
                confirmSender
            case .recover:
                recover
            case .refused:
                refused
            case .failed:
                failed
            }
            if let errorText {
                Text(errorText)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            if refuseFailed {
                Button(L10n.Onboarding.Server.retry) { Task { await refuseThenSignOut() } }
                    .buttonStyle(QuietButtonStyle(size: .regular))
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .task { await start() }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Onboarding.Account.approvalTitle)
                .font(BanditoFont.font(size: 34, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Onboarding.Account.approvalSubtitle)
                .font(BanditoFont.font(size: 15, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            DeviceCodeText(code: model?.ownFingerprint ?? "")
            Text(L10n.Onboarding.Account.approvalHint)
                .font(BanditoFont.font(size: 13.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineSpacing(2)
            HStack(spacing: 10) {
                waitingPulse
                Text(L10n.Onboarding.Account.approvalWaiting)
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            }
            Button(L10n.Onboarding.Account.noOtherDevice) { mode = .recover }
                .buttonStyle(.plain)
                .font(BanditoFont.font(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.signal)
        }
    }

    /// Animated wait: the dot pulses while the server is asked every three seconds.
    private var waitingPulse: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            PulseDot(t: context.date.timeIntervalSinceReferenceDate, color: Color.Bandito.signal)
        }
    }

    private var confirmSender: some View {
        let code: String = {
            if case .confirmSender(let senderCode)? = model?.phase { return senderCode }
            return ""
        }()
        return VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Onboarding.Account.senderTitle(code: code))
                .font(BanditoFont.font(size: 26, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineSpacing(2)
            DeviceCodeText(code: code)
            Text(L10n.Onboarding.Account.senderHint)
                .font(BanditoFont.font(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            HStack(spacing: 10) {
                Button(L10n.Onboarding.Account.codesMatch) { confirm() }
                    .buttonStyle(SignalButtonStyle())
                Button(L10n.Onboarding.Account.codesDiffer) {
                    Task { await refuseThenSignOut() }
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var refused: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.Account.refusedTitle)
                .font(BanditoFont.font(size: 26, weight: 600))
                .foregroundStyle(Color.Bandito.danger)
            Text(L10n.Onboarding.Account.refusedText)
                .font(BanditoFont.font(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            Button(L10n.Onboarding.Account.understood) { onNoAccess() }
                .buttonStyle(QuietButtonStyle())
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(errorText ?? L10n.Onboarding.Account.errorGeneric)
                .font(BanditoFont.font(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
            Button(L10n.Onboarding.Account.signOutAction) { Task { await signOut() } }
                .buttonStyle(QuietButtonStyle())
        }
    }

    private var recover: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Onboarding.Account.recoverTitle)
                .font(BanditoFont.font(size: 26, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Onboarding.Account.recoverText)
                .font(BanditoFont.font(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            ResetConfirmation {
                try await hub.recoverAccount()
                onFinished()
            } onCancel: {
                // Back to waiting when this came from "no other device"; otherwise there is nothing to go back to.
                if model != nil {
                    mode = .waiting
                } else {
                    Task { await signOut() }
                }
            } onSignInAgain: {
                Task { await signOut() }
            }
            Button(L10n.Onboarding.Account.signInAgain) { Task { await signOut() } }
                .buttonStyle(.plain)
                .font(BanditoFont.font(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
        }
    }

    /// Decides the screen from the server state. Waiting starts the poll; the poll belongs to this task,
    /// so leaving the screen cancels it.
    private func start() async {
        do {
            let (route, me) = try await hub.inspect()
            switch route {
            case .waitForApproval:
                guard let identity = hub.identity, let client = hub.client else { throw AccountHubError.notReady }
                let approval = DeviceApprovalModel(
                    backend: client, identity: identity, accountID: me.user.id, deviceID: me.device.id,
                    keys: hub.keys)
                model = approval
                mode = .waiting
                await approval.runPolling()
                switch approval.phase {
                case .confirmSender:
                    mode = .confirmSender
                case .failed(let message):
                    errorText = message
                    mode = .failed
                default:
                    break
                }
            case .recoverRequired:
                mode = .recover
            case .firstDevice, .ready:
                onFinished()
            }
        } catch {
            errorText = SignInMessages.setupText(for: error)
            mode = .failed
        }
    }

    /// The codes differ: this device is removed from the account, and only then is the person signed out.
    /// If the server refuses the removal, nothing is signed out; the person can try again.
    private func refuseThenSignOut() async {
        guard let model else { return }
        guard await model.refuse() else {
            refuseFailed = true
            errorText = L10n.Onboarding.Account.refuseFailed
            return
        }
        refuseFailed = false
        try? await hub.signOut()
        mode = .refused
    }

    private func confirm() {
        guard let model else { return }
        do {
            try model.confirmSender()
            onFinished()
        } catch {
            errorText = SignInMessages.text(for: error)
            mode = .failed
        }
    }

    private func signOut() async {
        try? await hub.signOut()
        onNoAccess()
    }
}

/// The sheet of an approved device: type the code the new device shows, then send it the sync key.
struct ApproveDeviceSheet: View {
    var device: PendingDevice
    var close: () -> Void

    @Environment(AccountHub.self) private var hub
    @State private var model: ApproveDeviceModel?
    @State private var setupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Onboarding.Account.approveTitle(name: device.name, platform: device.platform))
                .font(BanditoFont.font(size: 20, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Onboarding.Account.approveHowTo)
                .font(BanditoFont.font(size: 13.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
            Text(L10n.Onboarding.Account.approveThisMac)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
            DeviceCodeText(code: model?.ownFingerprint ?? hub.identity?.fingerprint ?? "")
            if let model {
                CodeEntryRow(model: model)
            }
            if let message = setupError ?? model?.errorText {
                Text(message)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
            HStack(spacing: 10) {
                Button(L10n.Onboarding.Account.approveAction) {
                    Task {
                        await model?.approve()
                        if model?.approved == true {
                            await hub.refreshPending()
                            close()
                        }
                    }
                }
                .buttonStyle(SignalButtonStyle())
                .disabled(!(model?.canApprove ?? false))
                Button(L10n.Onboarding.Account.rejectAction) {
                    Task {
                        if await model?.reject() == true {
                            await hub.refreshPending()
                            close()
                        }
                    }
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button(L10n.Common.close, action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(Color.Bandito.surface2)
        .task { build() }
    }

    private func build() {
        guard model == nil else { return }
        guard let identity = hub.identity, let client = hub.client else {
            setupError = L10n.Onboarding.Account.setupFailed
            return
        }
        let keys = hub.keys
        model = ApproveDeviceModel(device: device, backend: client, identity: identity, syncKey: {
            guard let key = try SyncKey.load(from: keys) else { throw DeviceApprovalError.noSyncKey }
            return key
        })
    }
}

/// Six-group entry of the 16-character code, pasted or typed. The formatting is `DeviceCodeInput`'s.
private struct CodeEntryRow: View {
    @Bindable var model: ApproveDeviceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Onboarding.Account.approveEnterCode)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
            TextField(
                "XXXX-XXXX-XXXX-XXXX",
                text: Binding(get: { model.code.value }, set: { model.enter($0) })
            )
            .textFieldStyle(.plain)
            .font(BanditoFont.font(size: 20, weight: 600, mono: true))
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.Bandito.text.opacity(0.12)))
            .accessibilityLabel(L10n.Onboarding.Account.approveEnterCode)
        }
    }
}

/// The banner above the main area: a device asks to join. Not modal; "Check" opens the approval sheet.
struct PendingDevicesBanner: View {
    @Environment(AccountHub.self) private var hub
    @State private var checking: PendingDevice?

    var body: some View {
        if let device = hub.pending.first {
            HStack(spacing: 12) {
                PulseDot(t: 0, color: Color.Bandito.signal)
                Text(L10n.Onboarding.Account.bannerText(name: device.name, platform: device.platform))
                    .font(BanditoFont.font(size: 13.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                Spacer()
                Button(L10n.Onboarding.Account.bannerCheck) { checking = device }
                    .buttonStyle(SignalButtonStyle(size: .regular))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.signal.opacity(0.35)))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .sheet(item: $checking) { device in
                ApproveDeviceSheet(device: device) { checking = nil }
            }
        }
    }
}

/// Settings → Account and sync: who is signed in, the devices with their codes, removing a device, resetting the
/// account and signing out. Without a session it offers the sign-in. After a sign-in the account's route decides:
/// a device that waits for approval (or needs a reset) gets the same screen as in onboarding.
struct AccountSheet: View {
    @Environment(AccountHub.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State private var me: Me?
    @State private var route: AccountRoute?
    @State private var loading = false
    @State private var errorText: String?
    @State private var resetting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.Onboarding.Account.settingsTitle)
                    .font(BanditoFont.font(size: 20, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Spacer()
                Button(L10n.Common.close) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.Bandito.text3)
            }
            if !hub.signedIn {
                Text(L10n.Onboarding.Account.settingsSignedOut)
                    .font(BanditoFont.font(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                AccountSignInView(onFinished: { _ in
                    Task { await reload() }
                }, onSkipAccount: nil, showsIllustration: false)
            } else if let route, route == .waitForApproval || route == .recoverRequired {
                DeviceApprovalStep(onFinished: {
                    Task { await reload() }
                }, onNoAccess: {
                    Task { await signOut() }
                })
            } else if let me {
                identityLine(me)
                devices(me)
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
                } else {
                    HStack(spacing: 10) {
                        Button(L10n.Onboarding.Account.resetAccountAction) { resetting = true }
                            .buttonStyle(QuietButtonStyle())
                        Button(L10n.Onboarding.Account.signOutAction) { Task { await signOut() } }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
            } else if loading {
                ProgressView().controlSize(.small)
            }
            if let errorText {
                Text(errorText)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(Color.Bandito.surface2)
        .task { await reload() }
    }

    private func identityLine(_ me: Me) -> some View {
        let who = me.user.email ?? me.user.githubLogin.map { "@\($0)" } ?? me.user.name ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Onboarding.Account.settingsSignedInAs(who: who))
                .font(BanditoFont.font(size: 14, weight: 500))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Onboarding.Account.settingsThisMac)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
            DeviceCodeText(code: hub.identity?.fingerprint ?? "")
        }
    }

    private func devices(_ me: Me) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(me.devices) { device in
                HStack(spacing: 10) {
                    Text(device.name)
                        .font(BanditoFont.font(size: 13.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                    Text(device.platform)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    if device.current {
                        Text(L10n.Onboarding.Account.settingsThisDevice)
                            .font(BanditoFont.font(size: 11.5, weight: 500))
                            .foregroundStyle(Color.Bandito.signal)
                    }
                    Spacer()
                    if !device.current {
                        Button(L10n.Onboarding.Account.settingsRemoveDevice) {
                            Task { await remove(device) }
                        }
                        .buttonStyle(.plain)
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .foregroundStyle(Color.Bandito.danger)
                    }
                }
            }
        }
    }

    /// Reads the route and the account from the server. Without a session there is nothing to read.
    private func reload() async {
        guard hub.signedIn else {
            route = nil
            me = nil
            return
        }
        loading = true
        defer { loading = false }
        do {
            _ = try await hub.prepare()
            let (current, account) = try await hub.inspect()
            route = current
            me = account
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

    private func signOut() async {
        do {
            try await hub.signOut()
            route = nil
            me = nil
        } catch {
            errorText = SignInMessages.text(for: error)
        }
    }
}
