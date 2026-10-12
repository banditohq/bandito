import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The four tabs of the app: Crew (home), Inbox, Activity and Settings. Only Crew has content so far; the other three
/// are placeholders until their screens are built (docs/IOS_APP.md).
struct RootView: View {
    /// The demo servers of the `-demo` launch arguments; empty without them.
    @State private var demoServers: [ServerModel] = []
    @State private var showsConnect = false

    var body: some View {
        TabView {
            CrewScreen(servers: demoServers, onConnect: { showsConnect = true })
                .tabItem { Label(L10n.Ios.Tab.crew, systemImage: "person.3") }
            ComingSoonTab(title: L10n.Ios.Tab.inbox)
                .tabItem { Label(L10n.Ios.Tab.inbox, systemImage: "tray") }
            ComingSoonTab(title: L10n.Ios.Tab.activity)
                .tabItem { Label(L10n.Ios.Tab.activity, systemImage: "list.bullet.rectangle") }
            ComingSoonTab(title: L10n.Settings.title)
                .tabItem { Label(L10n.Settings.title, systemImage: "gearshape") }
        }
        // Accents are the brand's signal orange (a link, a menu's chevron); the tab bar itself stays cream on warm dark.
        .tint(Color.Bandito.signal)
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard demoServers.isEmpty, IOSDemo.isRequested(in: arguments) else { return }
            demoServers = await IOSDemo.startServers(withTeam: !IOSDemo.isEmptyRequested(in: arguments))
        }
        .sheet(isPresented: $showsConnect) {
            ConnectPlaceholderSheet()
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
