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

    var body: some View {
        TabView {
            CrewTab(server: demoServer, onConnect: { showsConnect = true })
                .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
            ComingSoonTab(title: L10n.Ios.Tab.inbox)
                .tabItem { Label(L10n.Ios.Tab.inbox, systemImage: "tray") }
            ComingSoonTab(title: L10n.Ios.Tab.activity)
                .tabItem { Label(L10n.Ios.Tab.activity, systemImage: "list.bullet.rectangle") }
            ComingSoonTab(title: L10n.Settings.title)
                .tabItem { Label(L10n.Settings.title, systemImage: "gearshape") }
        }
        .task {
            guard demoServer == nil, IOSDemo.isRequested(in: ProcessInfo.processInfo.arguments) else { return }
            demoServer = await IOSDemo.start()
        }
        .sheet(isPresented: $showsConnect) {
            ConnectPlaceholderSheet()
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
