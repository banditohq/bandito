import BanditoDesign
import BanditoL10n
import SwiftUI

/// A section the Settings window should open on, asked for from elsewhere (for example "Manage servers" in the
/// server menu). The window takes it once; without a request it opens on General.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()

    var requested: SettingsSection?
}

/// Hands a route over to the main window: Settings closes, the main window comes forward with the route applied.
@MainActor
enum SettingsHandoff {
    static func openMainWindow(router: Router, _ route: (Router) -> Void) {
        route(router)
        // The key window is Settings when this runs from a Settings page.
        WindowActions.closeKeyWindow()
        WindowActions.showMainWindow()
    }
}

/// The Settings window (⌘,): 13 sections in a left navigation (Telegram only with a daemon that has it). Opens at
/// 900 × 640 pt, never smaller than 760 × 520.
public struct SettingsWindow: View {
    @Environment(AppModel.self) private var app
    @State private var section: SettingsSection = .general

    public init() {}

    /// The sections the current server can show. Telegram is listed only once the probe has answered that the daemon
    /// knows it: while the probe runs, or on an older daemon, the item is not there.
    private var sections: [SettingsSection] {
        let telegramShown = app.currentServer?.telegramSupport == .supported
        return SettingsSection.allCases.filter { $0 != .telegram || telegramShown }
    }

    /// Asks the current server once it is connected, and again when another server is chosen.
    private struct TelegramProbe: Hashable {
        let server: UUID?
        let connected: Bool
    }

    public var body: some View {
        HStack(spacing: 0) {
            navigation
                .frame(width: 240)
                .frame(maxHeight: .infinity)
                .background(Color.Bandito.bg)
            // A page can never push the navigation out of the window: it gets the leftover width and clips the rest.
            GeometryReader { _ in
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Color.Bandito.surface1)
        }
        .frame(minWidth: 760, idealWidth: 900, maxWidth: .infinity, minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear(perform: takeRequest)
        .onChange(of: SettingsNavigation.shared.requested) { _, _ in takeRequest() }
        .task(id: TelegramProbe(server: app.currentServer?.id, connected: app.currentServer?.info != nil)) {
            await app.currentServer?.checkTelegramSupport()
        }
        // Without a confirmed Telegram daemon the section is not listed; the window then moves to General.
        .onChange(of: app.currentServer?.telegramSupport ?? .unknown) { _, support in
            if support != .supported, section == .telegram { section = .general }
        }
    }

    private func takeRequest() {
        guard let requested = SettingsNavigation.shared.requested else { return }
        section = requested
        SettingsNavigation.shared.requested = nil
    }

    private var navigation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Settings.title)
                    .font(BanditoFont.display(size: 15.5, weight: 600))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.Bandito.text)
                    .padding(.horizontal, 10)
                    .padding(.top, 26)
                    .padding(.bottom, 14)
                ForEach(sections) { item in
                    let selected = item == section
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 10) {
                            SettingsBadge(symbol: item.symbol, tint: item.tint)
                            Text(item.title)
                                .font(BanditoFont.text(size: 13, weight: selected ? 600 : 400))
                                .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? Color.Bandito.signal.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                    }
                    .banditoButton(.row(cornerRadius: 10))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSection()
        case .account: AccountSection()
        case .servers: ServersSection()
        case .approvals: ApprovalsSection()
        case .usage: UsageSection()
        case .terminalFiles: TerminalFilesSection()
        case .browserScreen: BrowserScreenSection()
        case .keysGestures: KeysAndGesturesSection()
        case .notifications: NotificationsSection()
        case .telegram: TelegramSection()
        case .sounds: SoundsSection()
        case .appearance: AppearanceSection()
        case .updates: UpdatesSection()
        }
    }
}
