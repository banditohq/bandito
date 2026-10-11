import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Servers → one server → Main: the name the app shows, the icon and the color in the server menu and the
/// sidebar, whether the server opens at launch, and which of its notifications reach the person.
struct ServerMainSection: View {
    let server: ServerModel
    @Environment(AppModel.self) private var app
    @State private var nameDraft = ""

    var body: some View {
        SettingsGroup(title: L10n.ServerSettings.Main.title) {
            SettingsRow(title: L10n.ServerSettings.Main.Name.title, hint: L10n.ServerSettings.Main.Name.hint) {
                TextField(L10n.ServerSettings.Main.Name.placeholder, text: $nameDraft)
                    .banditoField()
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .frame(minWidth: 160, maxWidth: 260)
                    .onSubmit(commitName)
            }
            Divider().padding(.horizontal, 16)
            SettingsRow(title: L10n.ServerSettings.Main.Icon.title, hint: L10n.ServerSettings.Main.Icon.hint) {
                HStack(spacing: 6) {
                    ForEach(ServerIcon.allCases, id: \.self) { icon in
                        choice(selected: server.config.icon == icon, label: L10n.ServerSettings.Main.Icon.option) {
                            app.changeServer(server.id) { $0.iconName = icon.rawValue }
                        } content: {
                            Image(systemName: icon.rawValue)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.Bandito.text)
                        }
                    }
                }
            }
            Divider().padding(.horizontal, 16)
            SettingsRow(title: L10n.ServerSettings.Main.Tint.title, hint: L10n.ServerSettings.Main.Tint.hint) {
                HStack(spacing: 6) {
                    ForEach(ServerTint.allCases, id: \.self) { tint in
                        choice(selected: server.config.tint == tint, label: L10n.ServerSettings.Main.Tint.option) {
                            app.changeServer(server.id) { $0.tintName = tint.rawValue }
                        } content: {
                            Circle()
                                .fill(tint.color)
                                .frame(width: 16, height: 16)
                        }
                    }
                }
            }
            Divider().padding(.horizontal, 16)
            SettingsRow(
                title: L10n.ServerSettings.Main.Primary.title, hint: L10n.ServerSettings.Main.Primary.hint,
                keepsControlBeside: true
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { server.config.isPrimary },
                        set: { on in app.setPrimaryServer(on ? server.id : nil) })
                )
                .labelsHidden()
                .toggleStyle(BanditoToggleStyle())
            }
            Divider().padding(.horizontal, 16)
            SettingsRow(title: L10n.ServerSettings.Main.Notify.title, hint: L10n.ServerSettings.Main.Notify.hint) {
                SegmentedPicker(
                    selection: Binding(
                        get: { server.config.notifications },
                        set: { scope in app.changeServer(server.id) { $0.notifications = scope } }),
                    options: NotificationScope.allCases.map { ($0, $0.title) }
                )
                .fixedSize()
            }
        }
        .onAppear { nameDraft = server.config.name }
        .onChange(of: server.config.name) { _, name in nameDraft = name }
    }

    /// Saves the typed name. An empty name is not saved: the field goes back to the name the server has.
    private func commitName() {
        guard let name = ServerConfigRules.cleanName(nameDraft) else {
            nameDraft = server.config.name
            return
        }
        if name != server.config.name {
            app.changeServer(server.id) { $0.name = name }
        }
        nameDraft = name
    }

    /// One round choice of the icon or the color row. The chosen one has a cream ring.
    private func choice<Content: View>(
        selected: Bool, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(Color.Bandito.signal, lineWidth: 2).opacity(selected ? 1 : 0))
        }
        .banditoButton(.icon(size: 30, label: label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension ServerTint {
    /// The palette color of the tint: a `Color.Bandito` token, or a `BanditoPalette` badge color.
    var color: Color {
        switch self {
        case .signal: Color.Bandito.signal
        case .ok: Color.Bandito.ok
        case .info: Color.Bandito.info
        case .danger: Color.Bandito.danger
        case .teal: BanditoPalette.badgeTeal
        case .purple: BanditoPalette.badgePurple
        case .indigo: BanditoPalette.badgeIndigo
        case .pink: BanditoPalette.badgePink
        }
    }
}

extension NotificationScope {
    /// The choice's words in the Main section.
    var title: String {
        switch self {
        case .all: L10n.ServerSettings.Main.Notify.all
        case .needsYou: L10n.ServerSettings.Main.Notify.needsYou
        case .off: L10n.ServerSettings.Main.Notify.off
        }
    }
}
