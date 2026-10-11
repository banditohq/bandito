import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// A service the agent asked the person to connect (docs/ARCHITECTURE.md#connect-requests). Waiting: a card with the
/// service's logo, the agent's reason, and Connect / Not now. Over: a quiet line that says how it ended.
struct ConnectCard: View {
    var row: ConnectRow
    var agentName: String
    /// Starts the usual connection of the service (the sign-in in the browser, or the sheet of keys).
    var onConnect: () -> Void
    /// Tells the daemon the person does not want it. The card shows a failure and stays for another try.
    var onDecline: () async throws -> Void

    /// The catalog, for the service's name, colour and way of signing in. Read from the shared snapshot of the server.
    var catalog: [IntegrationCatalogEntry]

    private var entry: IntegrationCatalogEntry? { catalog.first { $0.id == row.service } }
    private var serviceName: String { entry?.name ?? row.service }

    var body: some View {
        if let outcome = row.outcome {
            ConnectResultLine(row: row, serviceName: serviceName, agentName: agentName, outcome: outcome)
        } else {
            PendingConnectCard(
                row: row, entry: entry, serviceName: serviceName, agentName: agentName,
                onConnect: onConnect, onDecline: onDecline)
        }
    }
}

// MARK: - Over

private struct ConnectResultLine: View {
    var row: ConnectRow
    var serviceName: String
    var agentName: String
    var outcome: ConnectOutcome

    private var icon: (name: String, tint: Color) {
        switch outcome {
        case .connected: ("checkmark.circle", Color.Bandito.ok)
        case .declined: ("xmark.circle", Color.Bandito.text3)
        case .expired: ("clock.badge.xmark", Color.Bandito.text3)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.tint)
            Text(AgentConnectText.line(outcome: outcome, service: serviceName, agent: agentName))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .font(BanditoFont.text(size: 12.5, weight: 400))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 4)
    }
}

/// The words of the line that closes a request.
enum AgentConnectText {
    /// The agent's reason in quotation marks, so that it reads as its words. Marks the agent put in already are kept.
    static func quoted(_ reason: String) -> String { "\u{201C}\(reason)\u{201D}" }

    static func line(outcome: ConnectOutcome, service: String, agent: String) -> String {
        switch outcome {
        case .connected: L10n.AgentConnect.connected(service: service, agent: agent)
        case .declined: L10n.AgentConnect.declined(service: service)
        case .expired: L10n.AgentConnect.expired(service: service)
        }
    }
}

// MARK: - Waiting

private struct PendingConnectCard: View {
    var row: ConnectRow
    var entry: IntegrationCatalogEntry?
    var serviceName: String
    var agentName: String
    var onConnect: () -> Void
    var onDecline: () async throws -> Void

    @State private var busy = false
    @State private var failure: UserFacingMessage?

    private var hint: String {
        entry?.usesOAuth == true
            ? L10n.AgentConnect.hintBrowser(agent: agentName)
            : L10n.AgentConnect.hintKeys(agent: agentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ConnectLogo(entry: entry, serviceID: row.service, name: serviceName, size: 44)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.AgentConnect.title(agent: agentName, service: serviceName))
                        .font(BanditoFont.text(size: 16, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let reason = row.shownReason {
                        // Words of the agent, shown as a quote with its name: the card is Bandito's, the reason is not.
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AgentConnectText.quoted(reason))
                                .font(BanditoFont.text(size: 13.5, weight: 400))
                                .foregroundStyle(Color.Bandito.text2)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text(L10n.AgentConnect.reasonBy(agent: agentName))
                                .font(BanditoFont.text(size: 12, weight: 400))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                        }
                    }
                    Text(hint)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let failure {
                UserFacingErrorView(message: failure)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button(action: onConnect) {
                    Text(L10n.Integrations.connect)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.signal())
                .disabled(busy)
                Button(action: decline) {
                    Text(L10n.AgentConnect.notNow)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.quiet())
                .disabled(busy)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x221C16), Color(hex: 0x1A1612)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
        )
        .padding(1)
        .background(border, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.Bandito.signal.opacity(0.3), radius: 24, x: 0, y: 14)
    }

    private var border: LinearGradient {
        LinearGradient(
            colors: [
                BanditoPalette.peach.opacity(0.75),
                Color.Bandito.signalFill.opacity(0.35),
                Color.Bandito.text.opacity(0.08),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func decline() {
        guard !busy else { return }
        busy = true
        failure = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await onDecline()
            } catch {
                failure = UserFacingError.message(for: error)
            }
        }
    }
}

/// The service's logo on its brand tile; the first letter of the name when the catalog has no logo for it.
struct ConnectLogo: View {
    var entry: IntegrationCatalogEntry?
    var serviceID: String
    var name: String
    var size: CGFloat

    var body: some View {
        MarketTileSurface(color: MarketTileStyle.color(hex: entry?.accent, name: serviceID), size: size) {
            if let logo = ServiceLogo.image(for: serviceID) {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.5, height: size * 0.5)
            } else if let entry {
                Image(systemName: IntegrationSymbol.name(icon: entry.icon, kind: entry.kind))
                    .font(.system(size: size * 0.44, weight: .semibold))
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(BanditoFont.display(size: size * 0.42, weight: 700))
            }
        }
        .accessibilityLabel(name)
    }
}
