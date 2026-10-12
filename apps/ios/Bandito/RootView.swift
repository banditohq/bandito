import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The four tabs of the app: Crew (home), Inbox, Activity and Settings. Only Crew has content so far; the other three
/// are placeholders until their screens are built (docs/IOS_APP.md).
struct RootView: View {
    /// The demo server of the `-demo` launch argument; nil without it.
    @State private var demoServer: ServerModel?
    @State private var showsConnect = false
    /// The servers this iPhone is connected to (saved list and Keychain tokens); loaded once at launch.
    @State private var session = ServerSession()
    /// A `bandito://pair` link opened from outside, until the connect sheet takes it.
    @State private var incomingLink: String?

    var body: some View {
        TabView {
            CrewTab(server: demoServer ?? session.active, onConnect: { showsConnect = true })
                .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
            ComingSoonTab(title: L10n.Ios.Tab.inbox)
                .tabItem { Label(L10n.Ios.Tab.inbox, systemImage: "tray") }
            ComingSoonTab(title: L10n.Ios.Tab.activity)
                .tabItem { Label(L10n.Ios.Tab.activity, systemImage: "list.bullet.rectangle") }
            ComingSoonTab(title: L10n.Settings.title)
                .tabItem { Label(L10n.Settings.title, systemImage: "gearshape") }
        }
        .task {
            session.loadIfNeeded()
            if PairingLaunchHooks.opensConnect() {
                incomingLink = PairingLaunchHooks.link()
                showsConnect = true
            }
            guard demoServer == nil, IOSDemo.isRequested(in: ProcessInfo.processInfo.arguments) else { return }
            demoServer = await IOSDemo.start()
        }
        .sheet(isPresented: $showsConnect) {
            ConnectServerView(session: session, incomingLink: $incomingLink, onClose: { showsConnect = false })
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "bandito" else { return }
            incomingLink = url.absoluteString
            showsConnect = true
        }
    }
}

/// Crew: the team of the demo server, or the welcome screen while no server is connected.
struct CrewTab: View {
    let server: ServerModel?
    let onConnect: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let server {
                    TeamList(server: server)
                } else {
                    WelcomeView(onConnect: onConnect)
                }
            }
            .navigationTitle(L10n.Ios.Tab.crew)
        }
    }
}

struct ComingSoonTab: View {
    let title: String

    var body: some View {
        NavigationStack {
            VStack(spacing: BanditoSpace.s3) {
                Image("Raccoon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(L10n.Ios.Tab.comingSoon)
                    .font(BanditoFont.text(size: 15))
                    .foregroundStyle(Color.Bandito.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(title)
        }
    }
}
