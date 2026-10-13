import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Pairs an iPhone: makes a one-time code (`pair.create`) and shows the QR code of the link the daemon built, the
/// six words to type instead, and where to tap on the iPhone. The QR code is drawn only for a link that passed
/// `PhonePairLink.parse`.
struct PhonePairSheet: View {
    let server: ServerModel
    /// A state to show without asking the server (the layout audit); nil on a live sheet.
    let preview: PhoneAccessRules.PairState?
    @Environment(\.dismiss) private var dismiss
    @State private var state: PhoneAccessRules.PairState?
    @State private var error: UserFacingMessage?
    /// Counts the codes asked for, so "New code" runs the request again.
    @State private var round = 0

    init(server: ServerModel, preview: PhoneAccessRules.PairState? = nil) {
        self.server = server
        self.preview = preview
        _state = State(initialValue: preview)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.ServerSettings.Phone.Pair.title)
                .font(BanditoFont.display(size: 15.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content
            ActionRow {
                Button(L10n.ServerSettings.Phone.Pair.new) { round += 1 }
                    .banditoButton(.quiet())
                    .fixedSize()
                Button(L10n.Common.close) { dismiss() }
                    .banditoButton(.signal())
                    .fixedSize()
            }
        }
        .padding(26)
        .frame(width: 420)
        .background(Color.Bandito.surface2)
        .task(id: round) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let error {
            UserFacingErrorView(message: error)
        } else {
            switch state {
            case nil:
                ProgressView().controlSize(.small).frame(height: 120)
            case .ready(let link, let code, let hosts, let minutes, let viaCloud):
                VStack(spacing: 14) {
                    Text(L10n.ServerSettings.Phone.Pair.steps)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    QRCodeView(text: link)
                    VStack(spacing: 4) {
                        Text(L10n.ServerSettings.Phone.Pair.codeLabel)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                        Text(code)
                            .font(BanditoFont.mono(size: 17, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L10n.ServerSettings.Phone.Pair.expires(minutes: String(minutes)))
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    if viaCloud {
                        Label(L10n.PhoneWizard.via, systemImage: "cloud.fill")
                            .font(BanditoFont.text(size: 12, weight: 500))
                            .foregroundStyle(Color.Bandito.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !hosts.isEmpty {
                        Text(L10n.ServerSettings.Phone.Pair.hosts(hosts: hosts.joined(separator: ", ")))
                            .font(BanditoFont.mono(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .expired:
                problem(L10n.ServerSettings.Phone.Pair.expired)
            case .notListening:
                problem(L10n.ServerSettings.Phone.Pair.notListening)
            case .updateApp:
                problem(L10n.ServerSettings.Phone.Pair.updateApp)
            case .invalid:
                problem(L10n.ServerSettings.Phone.Pair.invalid)
            }
        }
    }

    private func problem(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 13, weight: 400))
            .foregroundStyle(Color.Bandito.text2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func load() async {
        guard preview == nil else { return }
        state = nil
        error = nil
        do {
            let reply = try await server.createPairCode()
            // A newer request replaced this one (New code pressed again): keep the newer answer.
            guard !Task.isCancelled else { return }
            state = PhoneAccessRules.pairState(for: reply)
            // The code is taken off the screen when its time is up: no dead code and QR stay to be scanned.
            if case .ready = state {
                try await Task.sleep(for: PhoneAccessRules.shownFor(reply))
                state = .expired
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = UserFacingError.message(for: error)
        }
    }
}
