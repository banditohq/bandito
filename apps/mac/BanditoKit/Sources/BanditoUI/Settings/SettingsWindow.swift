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

/// The Settings window (⌘,): 13 sections in a left navigation. Opens at 980 × 680 pt, never smaller than 860 × 560.
public struct SettingsWindow: View {
    @State private var section: SettingsSection = .general

    public init() {}

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
        .frame(minWidth: 860, idealWidth: 980, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear(perform: takeRequest)
        .onChange(of: SettingsNavigation.shared.requested) { _, _ in takeRequest() }
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .padding(.horizontal, 10)
                    .padding(.top, 26)
                    .padding(.bottom, 14)
                ForEach(SettingsSection.allCases) { item in
                    let selected = item == section
                    Button {
                        section = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white)
                                .frame(width: 24, height: 24)
                                .background(item.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .accessibilityHidden(true)
                            Text(item.title)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? Color.Bandito.text.opacity(0.08) : .clear))
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
        case .workplaces: WorkplacesSection()
        case .terminalFiles: TerminalFilesSection()
        case .browserScreen: BrowserScreenSection()
        case .keysGestures: KeysAndGesturesSection()
        case .notifications: NotificationsSection()
        case .sounds: SoundsSection()
        case .appearance: AppearanceSection()
        case .updates: UpdatesSection()
        }
    }
}
