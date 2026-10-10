import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Shows the sign-in in progress over whatever mode is in front: the browser is open and the app waits, then
/// "Connected". It is driven by `OAuthSignIn.phase` alone; closing it gives the sign-in up.
struct OAuthSignInPresenter: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let oauth = app.oauth
        content.banditoSheet(
            isPresented: Binding(
                get: { oauth.isActive },
                set: { shown in if !shown { Task { await oauth.dismiss() } } }),
            dismissOnOutsideClick: false
        ) {
            OAuthSignInSheet(oauth: oauth)
        }
    }
}

struct OAuthSignInSheet: View {
    let oauth: OAuthSignIn

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
        switch oauth.phase {
        case .idle: ""
        case .starting(let name), .waiting(let name), .finishing(let name): name
        case .connected(let name, _): name
        case .failed(let name, _, _): name
        }
    }

    private var title: String {
        name.isEmpty ? L10n.Integrations.connect : L10n.Integrations.Oauth.title(name: name)
    }

    @ViewBuilder
    private var content: some View {
        switch oauth.phase {
        case .idle:
            EmptyView()
        case .starting:
            progress(L10n.Integrations.Oauth.starting)
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                progress(L10n.Integrations.Oauth.waiting)
                Text(L10n.Integrations.Oauth.waitingHint)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .finishing:
            progress(L10n.Integrations.Oauth.finishing)
        case .connected:
            Label {
                Text(L10n.Integrations.connected)
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
            switch oauth.phase {
            case .idle, .finishing:
                EmptyView()
            case .starting:
                Button(L10n.Common.cancel) { Task { await oauth.dismiss() } }
                    .banditoButton(.quiet())
                    .keyboardShortcut(.cancelAction)
            case .waiting:
                Button(L10n.Integrations.Oauth.openAgain) { oauth.reopenBrowser() }
                    .banditoButton(.quiet())
                Button(L10n.Common.cancel) { Task { await oauth.dismiss() } }
                    .banditoButton(.quiet())
                    .keyboardShortcut(.cancelAction)
            case .connected:
                Button(L10n.Integrations.Oauth.done) { Task { await oauth.dismiss() } }
                    .banditoButton(.signal())
                    .keyboardShortcut(.defaultAction)
            case .failed(_, _, let canRetry):
                Button(L10n.Common.close) { Task { await oauth.dismiss() } }
                    .banditoButton(.quiet())
                    .keyboardShortcut(.cancelAction)
                if canRetry {
                    Button(L10n.Integrations.Oauth.retry) { Task { await oauth.retry() } }
                        .banditoButton(.signal())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
