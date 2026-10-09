import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The menu bar icon: the raccoon mask, with an orange dot while someone waits for a decision.
public struct MenuBarLabel: View {
    private let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            RaccoonMask()
                .fill(.primary)
                .frame(width: 17, height: 17)
            if MenuBarContent.waitingCount(app) > 0 {
                Circle()
                    .fill(Color.Bandito.signal)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 20, height: 18)
    }
}

/// The menu bar window: approvals waiting for you, agents running, subscription limits, and the app's actions.
public struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(DemoStore.self) private var demo
    @State private var failure: UserFacingMessage?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 10)
            waitingSection
            workingSection
            limitsSection
            Divider()
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 0) {
                Button(L10n.Menubar.open) { WindowActions.showMainWindow() }
                    .buttonStyle(MenuRowStyle())
                    .brandFocusRing(shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button(PauseActions.pauseAllTitle(app.currentServer)) {
                    if let server = app.currentServer { PauseActions.toggleAll(on: server) }
                }
                .buttonStyle(MenuRowStyle())
                .brandFocusRing(shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(!PauseActions.available(on: app.currentServer))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 360)
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 9) {
            Text(L10n.App.name)
                .font(.system(size: 13, weight: .semibold))
            Text(app.servers.map { $0.info?.hostname ?? $0.config.name }.joined(separator: " · "))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
            Spacer(minLength: 0)
            let count = Self.waitingCount(app)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.Bandito.signal))
            }
        }
    }

    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(L10n.Menubar.waiting, tone: .signal)
                .padding(.horizontal, 8)
            let rows = Self.waiting(app)
            if rows.isEmpty {
                Text(L10n.Menubar.noneWaiting)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.horizontal, 8)
            }
            ForEach(rows) { row in
                approvalRow(row)
            }
            if let failure {
                UserFacingErrorView(message: failure)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.bottom, 8)
    }

    private func approvalRow(_ row: WaitingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                AgentAvatar(name: row.agent.name, size: 26)
                Text(row.agent.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(row.approval.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(L10n.Approval.deny) { resolve(row, .deny) }
                    .banditoButton(.quiet(size: .regular))
                Button(L10n.Approval.approve) { resolve(row, .allow) }
                    .banditoButton(.signal(size: .regular))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.signal.opacity(0.09)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.Bandito.signal.opacity(0.28)))
        .padding(.horizontal, 8)
    }

    private var workingSection: some View {
        let rows = Self.working(app)
        return VStack(alignment: .leading, spacing: 2) {
            SectionLabel(L10n.Menubar.working)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            if rows.isEmpty {
                Text(L10n.Menubar.nothingRunning)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.horizontal, 8)
            }
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.Bandito.ok)
                        .frame(width: 7, height: 7)
                    Text(row.agent.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(row.thread.preview ?? row.agent.cwd)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 8)
    }

    private var limitsSection: some View {
        let snapshot = UsageCards.snapshot(server: app.currentServer, demo: demo)
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.Usage.limits)
            ForEach(snapshot.cards.prefix(2)) { card in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(card.color.color)
                        .frame(width: 8, height: 8)
                    Text(card.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 6)
                    if let line = card.windows.min(by: { $0.remaining < $1.remaining }) {
                        Text("\(Int((line.remaining * 100).rounded()))%")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(line.remaining < 0.25 ? Color.Bandito.signal : Color.Bandito.text)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.text.opacity(0.04)))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    // MARK: data

    struct WaitingApproval: Identifiable {
        var server: ServerModel
        var agent: Agent
        var approval: ApprovalRow
        var id: String { approval.approvalId }
    }

    struct WorkingAgent: Identifiable {
        var agent: Agent
        var thread: AgentThread
        var id: String { agent.id }
    }

    static func waiting(_ app: AppModel) -> [WaitingApproval] {
        app.servers.flatMap { server in
            server.agents.flatMap { agent in
                server.thread(for: agent.id).pendingApprovals.map {
                    WaitingApproval(server: server, agent: agent, approval: $0)
                }
            }
        }
    }

    static func waitingCount(_ app: AppModel) -> Int {
        waiting(app).count
    }

    static func working(_ app: AppModel) -> [WorkingAgent] {
        app.servers.flatMap { server in
            server.agents.compactMap { agent -> WorkingAgent? in
                let thread = server.thread(for: agent.id)
                return thread.status == .working ? WorkingAgent(agent: agent, thread: thread) : nil
            }
        }
    }

    private func resolve(_ row: WaitingApproval, _ decision: Decision) {
        Task {
            do {
                try await row.server.resolve(row.approval.approvalId, decision)
                failure = nil
            } catch {
                failure = UserFacingError.message(for: error)
            }
        }
    }
}

/// A full-width menu row with a hover tint, like the menus of the system.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(configuration.isPressed ? Color.Bandito.text.opacity(0.10)
                            : Color.Bandito.text.opacity(hovered ? 0.05 : 0)))
        }
    }
}
