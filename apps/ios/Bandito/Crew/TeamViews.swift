import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The first screen of a person without a server: the raccoon, a welcome line and one action.
struct WelcomeView: View {
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: BanditoSpace.s5) {
            Spacer()
            Image("Raccoon")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            Text(L10n.Ios.Welcome.title)
                .font(BanditoFont.display(size: 24, weight: 700))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Text(L10n.Onboarding.Welcome.subtitle)
                .font(BanditoFont.text(size: 15))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: onConnect) {
                HStack(spacing: BanditoSpace.s2) {
                    Circle()
                        .fill(Color.Bandito.signalFill)
                        .frame(width: 7, height: 7)
                    Text(L10n.Empty.NoServers.action)
                }
            }
            .buttonStyle(SignalButtonStyle())
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg.ignoresSafeArea())
    }
}

/// The primary action: a cream capsule with an orange dot, as in the Mac app's `.signal` button. A small copy here
/// until the button styles move from BanditoUI into BanditoDesign.
struct SignalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.display(size: 14, weight: 600))
            .foregroundStyle(Color.Bandito.bg)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background(Capsule().fill(Color.Bandito.text))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// The agents of one server, by their status order the app already uses (`sortedAgents`).
struct TeamList: View {
    let server: ServerModel

    var body: some View {
        List(server.sortedAgents) { agent in
            AgentRow(agent: agent)
                .listRowBackground(Color.Bandito.surface1)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.Bandito.bg.ignoresSafeArea())
    }
}

struct AgentRow: View {
    let agent: Agent

    var body: some View {
        let status = agent.status ?? .idle
        HStack(spacing: BanditoSpace.s3) {
            Circle()
                .fill(status.tint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(BanditoFont.display(size: 14, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Text(agent.role)
                    .font(BanditoFont.text(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: BanditoSpace.s2)
            Text(status.label)
                .font(BanditoFont.text(size: 12, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
        }
        .padding(.vertical, BanditoSpace.s1)
        .accessibilityElement(children: .combine)
    }
}

extension AgentStatus {
    /// The word for the status, from the same strings as the Mac app.
    var label: String {
        switch self {
        case .idle: L10n.Status.idle
        case .working: L10n.Status.working
        case .needsYou: L10n.Status.needsYou
        case .error: L10n.Status.error
        case .offline: L10n.Status.offline
        }
    }

    /// The dot's color. Status is never color alone: the word sits next to it.
    var tint: Color {
        switch self {
        case .working: Color.Bandito.ok
        case .needsYou: Color.Bandito.signal
        case .error: Color.Bandito.danger
        case .idle, .offline: Color.Bandito.text3
        }
    }
}

/// The connect flow is not built yet: this sheet only shows where it will live.
struct ConnectPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: BanditoSpace.s4) {
                Image("Raccoon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text(L10n.Ios.Connect.placeholder)
                    .font(BanditoFont.text(size: 15))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
            }
            .padding(BanditoSpace.s6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(L10n.Server.Add.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.close) { dismiss() }
                }
            }
        }
    }
}
