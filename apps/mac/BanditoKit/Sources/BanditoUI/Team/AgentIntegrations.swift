import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The integrations an agent may use, as chips: "All connected" (the default) or the ticked ones. A disabled
/// integration cannot be ticked; it is shown, dimmed, so the owner sees why it is not offered.
struct AgentIntegrationsPicker: View {
    let integrations: [Integration]
    @Binding var choice: IntegrationChoice

    private var enabledIDs: Set<String> {
        Set(integrations.filter(\.enabled).map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                chip(L10n.Integrations.Agent.all, on: choice == .all) {
                    choice = .all
                }
                ForEach(integrations) { integration in
                    chip(integration.name, on: choice.isOn(integration.id, enabled: enabledIDs)) {
                        choice = choice.toggled(integration.id, enabled: enabledIDs)
                    }
                    .disabled(!integration.enabled)
                    .opacity(integration.enabled ? 1 : 0.45)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.Integrations.Agent.hint)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: on ? "checkmark" : "plus")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(BanditoFont.font(size: 12.5, weight: 500))
            .foregroundStyle(on ? Color.Bandito.text : Color.Bandito.text3)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(on ? Color.Bandito.text.opacity(0.06) : Color.clear, in: Capsule())
            .overlay {
                if on {
                    Capsule().stroke(Color.Bandito.line, lineWidth: 1)
                } else {
                    Capsule().stroke(
                        Color.Bandito.text.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(Capsule())
        }
        .banditoButton(.row(cornerRadius: 15, hoverOpacity: 0.04))
    }
}
