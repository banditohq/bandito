import BanditoDesign
import BanditoL10n
import SwiftUI

/// The gauge button in the sidebar footer. It shows the smallest share left among the windows of the
/// current agent's runtime (all runtimes when no agent is selected) and opens the usage popover.
struct UsageButton: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(DemoStore.self) private var demo

    var body: some View {
        @Bindable var router = router
        let open = router.usagePopoverOpen
        let snapshot = UsageCards.snapshot(server: app.currentServer, demo: demo)
        let percent = UsageCards.percentLeft(snapshot.cards, runtime: selectedRuntime)
        let text = percent.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"

        Button {
            router.usagePopoverOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.medium")
                    .font(.system(size: 14, weight: .medium))
                Text(text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.Bandito.text)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Capsule().fill(Color.Bandito.text.opacity(open ? 0.10 : 0.04)))
            .overlay(Capsule().strokeBorder(Color.Bandito.text.opacity(open ? 0.22 : 0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.Usage.title)
        .accessibilityLabel(percent == nil ? L10n.Usage.title : L10n.Usage.buttonAria(percent: text))
        .popover(isPresented: $router.usagePopoverOpen, arrowEdge: .top) {
            UsagePopover()
        }
    }

    /// The runtime of the agent whose chat is open, if it is one of the server's agents.
    private var selectedRuntime: String? {
        guard let id = router.selectedAgentID else { return nil }
        return app.currentServer?.agents.first { $0.id == id }?.runtime.rawValue
    }
}
