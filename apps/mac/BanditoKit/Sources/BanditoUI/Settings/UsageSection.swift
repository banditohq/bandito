import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Subscriptions and limits: the same cards as the usage popover, with a refresh button.
struct UsageSection: View {
    @Environment(AppModel.self) private var app
    @Environment(DemoStore.self) private var demo
    @State private var refreshing = false
    @State private var error: UserFacingMessage?

    var body: some View {
        let snapshot = UsageCards.snapshot(server: app.currentServer, demo: demo)
        SettingsPage(title: SettingsSection.usage.title, intro: L10n.Settings.Usage.intro) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        if snapshot.isExample {
                            ExampleChip()
                        }
                        Spacer(minLength: 8)
                        Button(L10n.Usage.refresh) {
                            refresh()
                        }
                        .banditoButton(.quiet())
                        .disabled(refreshing || app.currentServer == nil)
                    }
                    if snapshot.cards.isEmpty {
                        Text(L10n.Usage.empty)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.Bandito.text2)
                    }
                    ForEach(snapshot.cards) { card in
                        UsageCardView(card: card, example: snapshot.isExample, now: Date())
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .banditoCard()
                    }
                    if let error {
                        UserFacingErrorView(message: error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
    }

    private func refresh() {
        guard let server = app.currentServer else { return }
        refreshing = true
        error = nil
        Task {
            do {
                try await server.refreshUsage(force: true)
            } catch {
                self.error = UserFacingError.message(for: error)
            }
            refreshing = false
        }
    }
}
