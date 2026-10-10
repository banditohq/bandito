import BanditoDesign
import BanditoL10n
import SwiftUI

/// The gauge button in the sidebar footer. It shows the share used in the most filled window of the current
/// agent's runtime (all runtimes when no agent is selected), coloured by level, and opens the usage popover.
struct UsageButton: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(DemoStore.self) private var demo

    var body: some View {
        @Bindable var router = router
        let open = router.usagePopoverOpen
        let snapshot = UsageCards.snapshot(server: app.currentServer, demo: demo)
        // The share used in the window that is closest to its limit; with no limits known, only the icon.
        let fullest = UsageCards.fullestWindow(snapshot.cards, runtime: selectedRuntime)
        let text = fullest.map { "\($0.usedPercent)%" }
        let level = fullest.map { UsageLevel(usedPercent: $0.usedPercent) }

        Button {
            router.usagePopoverOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.medium")
                    .font(.system(size: 14, weight: .medium))
                if let text {
                    Text(text)
                        .font(BanditoFont.text(size: 12.5, weight: 600))
                        .monospacedDigit()
                        .foregroundStyle(level?.color ?? Color.Bandito.text)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(Color.Bandito.text)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Capsule().fill(Color.Bandito.text.opacity(open ? 0.10 : 0.04)))
            .overlay(Capsule().strokeBorder(Color.Bandito.text.opacity(open ? 0.22 : 0.10)))
            .contentShape(Capsule())
        }
        .banditoButton(.row(cornerRadius: 17))
        .help(
            fullest.map {
                L10n.Usage.fullestHelp(percent: "\($0.usedPercent)%", runtime: $0.runtimeName, window: $0.windowLabel)
            } ?? L10n.Usage.limits
        )
        .accessibilityLabel(text.map { L10n.Usage.buttonAria(percent: $0) } ?? L10n.Usage.limits)
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
