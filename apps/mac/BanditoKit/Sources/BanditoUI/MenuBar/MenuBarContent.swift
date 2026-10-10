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
    @Environment(Router.self) private var router
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
            let unlisted = Self.unlisted(app)
            if rows.isEmpty && unlisted.isEmpty {
                Text(L10n.Menubar.noneWaiting)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.horizontal, 8)
            }
            ForEach(rows) { row in
                approvalRow(row)
            }
            // Approvals of agents whose chat is not open: the count is known, the details come with the chat.
            ForEach(unlisted) { row in
                unlistedRow(row)
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
                AgentAvatarView(agent: row.agent, server: row.server, size: 26)
                Text(row.agent.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(row.approval.title)
                    .font(.system(size: 12))
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

    private func unlistedRow(_ row: WaitingAgent) -> some View {
        HStack(spacing: 9) {
            AgentAvatarView(agent: row.agent, server: row.server, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.agent.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.Menubar.approvalsWaiting(count: row.count))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(L10n.Menubar.openChat) {
                // The same as choosing the agent in the main window: it is selected, remembered and shown in Team.
                router.selectAgent(row.agent.id, on: row.server)
                router.select(mode: .team)
                WindowActions.showMainWindow()
            }
                .banditoButton(.quiet(size: .regular))
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
                    Text(AgentPreview.text(thread: row.thread, agent: row.agent) ?? row.agent.cwd)
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
                    if let fullest = UsageCards.fullestWindow([card], runtime: nil) {
                        Text("\(fullest.usedPercent)%")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(UsageLevel(usedPercent: fullest.usedPercent).color)
                            .help(L10n.Usage.fullestHelp(
                                percent: "\(fullest.usedPercent)%", runtime: fullest.runtimeName,
                                window: fullest.windowLabel))
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

    /// An agent with approvals the app has not listed (its chat is not loaded): the count only.
    struct WaitingAgent: Identifiable {
        var server: ServerModel
        var agent: Agent
        var count: Int
        var id: String { agent.id }
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

    /// Approvals of agents whose chat is not loaded, as a count per agent. Together with `waiting` this is every
    /// approval the server reports (`ServerModel.pendingApprovalCount`).
    static func unlisted(_ app: AppModel) -> [WaitingAgent] {
        app.servers.flatMap { server in
            server.agents.compactMap { agent -> WaitingAgent? in
                let listed = server.thread(for: agent.id).pendingApprovals.count
                let count = server.pendingApprovalCount(of: agent.id) - listed
                return count > 0 ? WaitingAgent(server: server, agent: agent, count: count) : nil
            }
        }
    }

    static func waitingCount(_ app: AppModel) -> Int {
        app.servers.reduce(0) { total, server in
            total + server.agents.reduce(0) { $0 + server.pendingApprovalCount(of: $1.id) }
        }
    }

    static func working(_ app: AppModel) -> [WorkingAgent] {
        app.servers.flatMap { server in
            server.agents.compactMap { agent -> WorkingAgent? in
                guard server.status(of: agent.id) == .working else { return nil }
                return WorkingAgent(agent: agent, thread: server.thread(for: agent.id))
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
