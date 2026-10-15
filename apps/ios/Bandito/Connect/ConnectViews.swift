import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

/// "Connect a server": the sheet that pairs this iPhone with a daemon (docs/IOS_APP.md, Key flows). The camera reads the
/// QR code from the Mac, a link can be pasted or opened from outside, and an address can be typed. When it works the
/// server is kept and the Crew screen shows its team.
struct ConnectServerView: View {
    let session: ServerSession
    /// A `bandito://pair` link opened from outside; handled once and cleared.
    @Binding var incomingLink: String?
    /// The way the person chose before the sheet opened (the onboarding's last step).
    let start: OnboardingConnectMode
    let onClose: () -> Void
    /// Signs in to the Bandito account instead (the servers of the Mac come by themselves); nil when already signed in.
    let onSignIn: (() -> Void)?

    @State private var model: PairModel

    init(
        session: ServerSession, incomingLink: Binding<String?>, start: OnboardingConnectMode = .scanCode,
        onSignIn: (() -> Void)? = nil, onJoin: (@MainActor (JoinTicket) -> Void)? = nil, onClose: @escaping () -> Void
    ) {
        self.session = session
        _incomingLink = incomingLink
        self.start = start
        self.onSignIn = onSignIn
        self.onClose = onClose
        // "Type an address" on the onboarding opens the sheet on the form itself.
        let model = PairModel(session: session, startsOnTypedForm: start == .typeAddress && incomingLink.wrappedValue == nil)
        model.onJoin = onJoin
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .choose:
                    ChooseStep(model: model, onSignIn: onSignIn)
                case .manual:
                    ManualStep(model: model)
                case .confirmLink(let request, let origin):
                    ConfirmLinkStep(request: request, origin: origin, model: model)
                case .trust(let request, let fingerprint):
                    TrustStep(request: request, fingerprint: fingerprint, model: model)
                case .working:
                    WorkingStep()
                case .done(_, let name, let route):
                    DoneStep(initialName: name, route: route, model: model, onClose: onClose)
                case .failed(let problem, _):
                    FailedStep(problem: PairProblemText(problem), model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(L10n.Server.Add.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    switch model.phase {
                    case .manual, .confirmLink, .trust:
                        Button(L10n.Common.back) { model.backToChoose() }
                    case .done:
                        EmptyView()
                    default:
                        // Not while a pairing runs: cancelling it can leave the device on the server with no token here.
                        Button(L10n.Common.close) {
                            model.cancel()
                            onClose()
                        }
                        .disabled(model.isWorking)
                    }
                }
            }
        }
        .task(id: incomingLink) {
            guard let link = incomingLink else { return }
            incomingLink = nil
            model.submitLink(link, origin: PairingLaunchHooks.linkOrigin())
        }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled(model.isWorking)
    }
}

// MARK: Steps

/// The scanner, the paste button and the way to type an address.
private struct ChooseStep: View {
    let model: PairModel
    let onSignIn: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: BanditoSpace.s5) {
                VStack(spacing: BanditoSpace.s2) {
                    Text(L10n.Ios.Connect.Scan.title)
                        .font(BanditoFont.display(size: 20, weight: 700))
                        .foregroundStyle(Color.Bandito.text)
                        .multilineTextAlignment(.center)
                    Text(L10n.Ios.Connect.Scan.hint)
                        .font(BanditoFont.text(size: 14))
                        .foregroundStyle(Color.Bandito.text2)
                        .multilineTextAlignment(.center)
                }
                .fixedSize(horizontal: false, vertical: true)
                ScannerBox { text in
                    let isLink = PairInput.containsLink(text) || JoinTicket.find(in: text) != nil
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(isLink ? .success : .warning)
                    model.submitLink(text, origin: .scan)
                }
                VStack(spacing: BanditoSpace.s3) {
                    Text(L10n.Ios.Connect.Paste.hint)
                        .font(BanditoFont.text(size: 13))
                        .foregroundStyle(Color.Bandito.text3)
                    BrandPasteButton { text in model.submitLink(text, origin: .paste) }
                    // The hint above offers the account; this is the way to it.
                    if let onSignIn {
                        Button {
                            onSignIn()
                        } label: {
                            Label(L10n.Ios.Settings.Account.signIn, systemImage: "person.crop.circle")
                        }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityHint(L10n.Ios.Settings.Account.signInHint)
                        .accessibilityIdentifier("connect.signIn")
                    }
                    Button(L10n.Ios.Connect.Manual.button) { model.showManual() }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("connect.manualButton")
                }
            }
            .padding(BanditoSpace.s5)
        }
    }
}

/// The camera box: the live picture with a viewfinder, or the reason it is not there (not asked yet, off, no camera).
/// Shared by the connect sheet and the sign-in scanner.
struct ScannerBox: View {
    var onCode: @MainActor (String) -> Void
    @State private var access = CameraPermission.current()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.Bandito.surface1)
            switch access {
            case .allowed:
                QRScannerView(isActive: true, onCode: onCode)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                ViewfinderFrame()
            case .notAsked:
                explain(text: L10n.Ios.Connect.Camera.reason, symbol: "camera") {
                    Button(L10n.Ios.Connect.Camera.allow) {
                        Task { access = await CameraPermission.request() }
                    }
                    .buttonStyle(SignalButtonStyle())
                    .accessibilityIdentifier("connect.allowCamera")
                }
            case .denied:
                explain(text: L10n.Ios.Connect.Camera.denied, symbol: "camera.fill") {
                    Button(L10n.Ios.Connect.Camera.openSettings) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            case .unavailable:
                explain(text: L10n.Ios.Connect.Scan.noCamera, symbol: "camera.metering.unknown") { EmptyView() }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Ios.Connect.Scan.title)
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings with the camera allowed.
            if phase == .active { access = CameraPermission.current() }
        }
    }

    private func explain<Action: View>(text: String, symbol: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: BanditoSpace.s3) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(Color.Bandito.text3)
            Text(text)
                .font(BanditoFont.text(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .padding(BanditoSpace.s5)
    }
}

/// Four corners over the camera picture, as a viewfinder.
private struct ViewfinderFrame: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.68
            let arm = side * 0.22
            Path { path in
                let rect = CGRect(
                    x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2, width: side, height: side)
                for (corner, dx, dy) in [
                    (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                    (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
                ] {
                    path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
                }
            }
            .stroke(Color.Bandito.signal, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An address, the six words and, if the person has it, the fingerprint.
private struct ManualStep: View {
    let model: PairModel
    @State private var address = ""
    @State private var code = ""
    @State private var fingerprint = ""
    @FocusState private var focus: Field?

    private enum Field { case address, code, fingerprint }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BanditoSpace.s5) {
                field(
                    title: L10n.Ios.Connect.Manual.address, hint: L10n.Ios.Connect.Manual.addressHint, text: $address,
                    field: .address, id: "connect.manual.address", keyboard: .URL, mono: false)
                field(
                    title: L10n.Ios.Connect.Manual.code, hint: L10n.Ios.Connect.Manual.codeHint, text: $code, field: .code,
                    id: "connect.manual.code", keyboard: .asciiCapable, mono: true)
                field(
                    title: L10n.Ios.Connect.Manual.fingerprint, hint: L10n.Ios.Connect.Manual.fingerprintHint,
                    text: $fingerprint, field: .fingerprint, id: "connect.manual.fingerprint", keyboard: .asciiCapable,
                    mono: true)
                Button(L10n.Ios.Connect.Manual.submit) {
                    focus = nil
                    model.submitManual(address: address, code: code, fingerprint: fingerprint)
                }
                .buttonStyle(SignalButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("connect.manual.submit")
            }
            .padding(BanditoSpace.s5)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func field(
        title: String, hint: String, text: Binding<String>, field: Field, id: String, keyboard: UIKeyboardType, mono: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s2) {
            Text(title)
                .font(BanditoFont.text(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text2)
            TextField("", text: text, axis: .vertical)
                .lineLimit(1...3)
                .font(mono ? BanditoFont.mono(size: 14) : BanditoFont.text(size: 16))
                .foregroundStyle(Color.Bandito.text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .padding(BanditoSpace.s3)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.surface1))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
                .accessibilityIdentifier(id)
                .accessibilityLabel(title)
            Text(hint)
                .font(BanditoFont.text(size: 12))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A link from outside (pasted or opened): who it says it is, and a button.
private struct ConfirmLinkStep: View {
    let request: PairRequest
    let origin: LinkOrigin
    let model: PairModel

    var body: some View {
        StepCard(symbol: "link", tint: Color.Bandito.signal) {
            Text(L10n.Ios.Connect.Confirm.title(name: request.name))
                .font(BanditoFont.display(size: 20, weight: 700))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Text(
                request.isRelayOnly
                    ? (origin == .scan ? L10n.Ios.Connect.Confirm.bodyScanCloud : L10n.Ios.Connect.Confirm.bodyCloud)
                    : origin == .scan
                        ? L10n.Ios.Connect.Confirm.bodyScan(address: request.hosts.joined(separator: ", "))
                        : L10n.Ios.Connect.Confirm.body(address: request.hosts.joined(separator: ", "))
            )
                .font(BanditoFont.text(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
        } actions: {
            Button(L10n.Ios.Connect.Confirm.action) { model.confirmLink() }
                .buttonStyle(SignalButtonStyle())
                .accessibilityIdentifier("connect.confirm")
            Button(L10n.Common.cancel) { model.backToChoose() }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

/// TOFU: the fingerprint the server presented, to compare with the Mac's before anything else is sent.
private struct TrustStep: View {
    let request: PairRequest
    let fingerprint: String
    let model: PairModel

    var body: some View {
        StepCard(symbol: "checkmark.shield", tint: Color.Bandito.signal) {
            Text(L10n.Ios.Connect.Trust.title)
                .font(BanditoFont.display(size: 20, weight: 700))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Text(L10n.Ios.Connect.Trust.body)
                .font(BanditoFont.text(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            VStack(spacing: BanditoSpace.s1) {
                Text(L10n.Ios.Connect.fingerprint)
                    .font(BanditoFont.text(size: 12, weight: 600))
                    .foregroundStyle(Color.Bandito.text3)
                ForEach(FingerprintLines.lines(fingerprint), id: \.self) { line in
                    Text(line)
                        .font(BanditoFont.mono(size: 13, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                }
            }
            .padding(BanditoSpace.s3)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.surface1))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connect.trust.fingerprint")
        } actions: {
            Button(L10n.Ios.Connect.Trust.action) { model.confirmTrust() }
                .buttonStyle(SignalButtonStyle())
                .accessibilityIdentifier("connect.trust.confirm")
            Button(L10n.Common.cancel) { model.backToChoose() }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

private struct WorkingStep: View {
    var body: some View {
        VStack(spacing: BanditoSpace.s4) {
            ProgressView()
            Text(L10n.Ios.Connect.working)
                .font(BanditoFont.text(size: 15))
                .foregroundStyle(Color.Bandito.text2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connect.working")
    }
}

/// Connected: the server's name, which the person may change, and Done.
private struct DoneStep: View {
    let initialName: String
    let route: ConnectionRoute?
    let model: PairModel
    let onClose: () -> Void
    @State private var name = ""

    var body: some View {
        StepCard(symbol: "checkmark.circle.fill", tint: Color.Bandito.ok) {
            Text(L10n.Ios.Connect.Done.title)
                .font(BanditoFont.display(size: 22, weight: 700))
                .foregroundStyle(Color.Bandito.text)
                .accessibilityIdentifier("connect.done.title")
            if let route {
                Label(
                    route == .cloud ? L10n.Ios.Connect.Done.viaCloud : L10n.Ios.Connect.Done.viaNetwork,
                    systemImage: route == .cloud ? "cloud.fill" : "wifi"
                )
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("connect.done.route")
            }
            VStack(alignment: .leading, spacing: BanditoSpace.s2) {
                Text(L10n.Ios.Connect.Done.nameLabel)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text2)
                TextField("", text: $name)
                    .font(BanditoFont.text(size: 16))
                    .foregroundStyle(Color.Bandito.text)
                    .submitLabel(.done)
                    .padding(BanditoSpace.s3)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.surface1))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
                    .accessibilityIdentifier("connect.done.name")
                    .accessibilityLabel(L10n.Ios.Connect.Done.nameLabel)
            }
        } actions: {
            Button(L10n.Ios.Connect.Done.action) {
                model.finish(name: name)
                onClose()
            }
            .buttonStyle(SignalButtonStyle())
            .accessibilityIdentifier("connect.done.action")
        }
        .onAppear { name = initialName }
    }
}

/// What went wrong, in plain words, with the way back. A server that is not the one paired is an alarm.
private struct FailedStep: View {
    let problem: PairProblemText
    let model: PairModel

    var body: some View {
        StepCard(
            symbol: problem.isAlarm ? "exclamationmark.shield.fill" : "exclamationmark.triangle",
            tint: problem.isAlarm ? Color.Bandito.danger : Color.Bandito.text3
        ) {
            if let title = problem.title {
                Text(title)
                    .font(BanditoFont.display(size: 20, weight: 700))
                    .foregroundStyle(problem.isAlarm ? Color.Bandito.danger : Color.Bandito.text)
                    .multilineTextAlignment(.center)
            }
            Text(problem.message)
                .font(BanditoFont.text(size: 15))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("connect.error")
        } actions: {
            Button(L10n.Ios.Connect.Error.tryAgain) { model.tryAgain() }
                .buttonStyle(SignalButtonStyle())
                .accessibilityIdentifier("connect.tryAgain")
        }
    }
}

/// A centred column: a symbol, the text, the buttons. Scrolls when the text is large (Dynamic Type).
private struct StepCard<Content: View, Actions: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: BanditoSpace.s5) {
                Image(systemName: symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(spacing: BanditoSpace.s3) { content }
                VStack(spacing: BanditoSpace.s3) { actions }
            }
            .padding(BanditoSpace.s6)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The system's paste button (it reads the clipboard without the "Allow paste" question), dressed as the brand's capsule:
/// the system button sits over the drawn one, invisible, and takes the touch.
private struct BrandPasteButton: View {
    let onPaste: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: BanditoSpace.s2) {
            Image(systemName: "doc.on.clipboard")
            Text(L10n.Ios.Connect.Paste.action)
        }
        .font(BanditoFont.display(size: 14, weight: 600))
        .foregroundStyle(Color.Bandito.text)
        .padding(.horizontal, 22)
        .frame(minHeight: 46)
        .background(Capsule().fill(Color.Bandito.surface2))
        .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
        .overlay {
            PasteButton(payloadType: String.self) { strings in
                let text = strings.joined(separator: " ")
                Task { @MainActor in onPaste(text) }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .opacity(0.015)
            .accessibilityLabel(L10n.Ios.Connect.Paste.action)
            .accessibilityIdentifier("connect.paste")
        }
        .contentShape(Capsule())
    }
}
