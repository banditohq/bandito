import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Approvals: rules for what agents may do without asking, and the checks the daemon always runs.
struct ApprovalsSection: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var rules: [Rule] = []
    @State private var pattern = ""
    @State private var action: RuleAction = .ask
    /// "*" for every agent, otherwise an agent id.
    @State private var scope = "*"
    @State private var error: UserFacingMessage?

    /// Checks the daemon runs on every server (docs/ARCHITECTURE.md#approvals-policy). Shown, not editable.
    private static let builtin = [
        "git push*", "git reset --hard*", "rm -rf*", "*deploy*", "npm publish*", "cargo publish*",
        "kubectl delete*", "terraform apply*", "*drop table*", "docker system prune*",
    ]

    var body: some View {
        let server = app.currentServer
        SettingsPage(title: SettingsSection.approvals.title, intro: L10n.Settings.Approvals.intro) {
            VStack(alignment: .leading, spacing: 18) {
                if let server, server.supports("rules") {
                    newRule(server)
                    rulesTable(server)
                } else if server == nil {
                    noServer
                } else {
                    Text(L10n.Server.updateNote)
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                }
                builtinChecks
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: server?.info != nil) {
            await reload(server)
        }
        // An agent that is deleted takes its rule's scope back to "all agents".
        .onChange(of: server?.agents.map(\.id) ?? []) { _, ids in
            scope = SelectChoices.scope(scope, agentIDs: ids)
        }
    }

    /// No server selected: say so and offer the way to add one. Same action as Settings → Servers.
    private var noServer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Server.noServer)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
            Button(L10n.Settings.Servers.add) {
                router.sheet = .addServer
            }
            .banditoButton(.signal())
        }
    }

    private func newRule(_ server: ServerModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Settings.Approvals.newRule)
                .font(BanditoFont.text(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            // The pattern gets the full width; the choices and the button share the row below, so nothing is squeezed
            // at the smallest window size.
            labeled(L10n.Settings.Approvals.when) {
                TextField(L10n.Settings.Approvals.patternPlaceholder, text: $pattern)
                    .banditoField()
                    .font(BanditoFont.mono(size: 13, weight: 400))
                    .onSubmit { add(server) }
            }
            HStack(alignment: .bottom, spacing: 10) {
                labeled(L10n.Settings.Approvals.then) {
                    BanditoSelect(
                        selection: $action, sections: [SelectSection(options: actionChoices)],
                        label: L10n.Settings.Approvals.then, placeholder: L10n.Settings.Approvals.ask,
                        field: { SelectFieldView(option: $0?.titleOnly, placeholder: L10n.Settings.Approvals.ask) },
                        footer: { _ in EmptyView() })
                }
                .frame(width: 150)
                labeled(L10n.Settings.Approvals.forWhom) {
                    BanditoSelect(
                        selection: $scope, sections: [SelectSection(options: scopeChoices(server))],
                        label: L10n.Settings.Approvals.forWhom, placeholder: L10n.Settings.Approvals.allAgents,
                        field: { SelectFieldView(option: $0?.titleOnly, placeholder: L10n.Settings.Approvals.allAgents) },
                        footer: { _ in EmptyView() })
                }
                .frame(width: 170)
                Spacer(minLength: 0)
                Button(L10n.Settings.Approvals.add) { add(server) }
                    .banditoButton(.lightPill())
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L10n.Settings.Approvals.wildcardNote)
                .font(BanditoFont.text(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            if let error {
                UserFacingErrorView(message: error)
            }
        }
        .padding(14)
        .banditoCard()
    }

    /// What to do with a matching action, each with what it means (`SelectChoices.approvalActions`).
    private var actionChoices: [SelectOption<RuleAction>] {
        SelectChoices.approvalActions(
            allow: .init(title: L10n.Settings.Approvals.allow, subtitle: L10n.Settings.Approvals.allowDesc),
            ask: .init(title: L10n.Settings.Approvals.ask, subtitle: L10n.Settings.Approvals.askDesc),
            deny: .init(title: L10n.Settings.Approvals.deny, subtitle: L10n.Settings.Approvals.denyDesc))
    }

    /// "All agents", then each agent with its avatar colour as a dot (the colour the sidebar gives it by name).
    private func scopeChoices(_ server: ServerModel) -> [SelectOption<String>] {
        SelectChoices.scopes(
            allAgentsTitle: L10n.Settings.Approvals.allAgents,
            agents: server.agents.map { agent in
                (
                    id: agent.id, name: agent.name,
                    tint: AvatarResolver.resolve(name: agent.name, color: nil, face: .auto).color.color
                )
            })
    }

    private func rulesTable(_ server: ServerModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SectionLabel(L10n.Settings.Approvals.columnAction).frame(maxWidth: .infinity, alignment: .leading)
                SectionLabel(L10n.Settings.Approvals.columnBehavior).frame(width: 130, alignment: .leading)
                SectionLabel(L10n.Settings.Approvals.columnScope).frame(width: 150, alignment: .leading)
                Color.clear.frame(width: 30)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.Bandito.text.opacity(0.025))
            if rules.isEmpty {
                Text(L10n.Settings.Approvals.empty)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .padding(16)
            }
            ForEach(rules) { rule in
                HStack(spacing: 12) {
                    Text(rule.pattern)
                        .font(BanditoFont.mono(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    behaviorPill(rule.action)
                        .frame(width: 130, alignment: .leading)
                    Text(scopeName(rule.agentId, server: server))
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    Button {
                        Task { await delete(rule, server: server) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .banditoButton(.icon(size: 26, label: L10n.Settings.Approvals.deleteAria(pattern: rule.pattern)))
                    .help(L10n.Settings.Approvals.deleteAria(pattern: rule.pattern))
                    .frame(width: 30)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1) }
            }
        }
        .banditoCard()
    }

    private var builtinChecks: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L10n.Settings.Approvals.builtin)
            Text(L10n.Settings.Approvals.builtinHint)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Self.builtin, id: \.self) { item in
                    chip(item, font: BanditoFont.mono(size: 12), color: Color.Bandito.text2)
                }
                chip(L10n.Settings.Approvals.outsideProject, font: BanditoFont.text(size: 12), color: Color.Bandito.text2)
            }
            SectionLabel(L10n.Settings.Approvals.browserChecks)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Self.browserChecks, id: \.self) { item in
                    chip(item, font: BanditoFont.text(size: 12), color: Color(hex: 0xA3BDEB))
                }
            }
        }
    }

    private static var browserChecks: [String] {
        [
            L10n.Settings.Approvals.Browser.pay, L10n.Settings.Approvals.Browser.send,
            L10n.Settings.Approvals.Browser.delete, L10n.Settings.Approvals.Browser.login,
        ]
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            content()
        }
    }

    private func chip(_ text: String, font: Font, color: Color) -> some View {
        // A chip stays inside its grid cell: a long text is cut in the middle and the full text shows on hover.
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.Bandito.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.Bandito.text.opacity(0.07)))
    }

    private func behaviorPill(_ action: RuleAction) -> some View {
        let (text, tint): (String, Color) = switch action {
        case .allow: (L10n.Settings.Approvals.allow, Color(hex: 0xC8DCC3))
        case .ask: (L10n.Settings.Approvals.ask, Color.Bandito.signal)
        case .deny: (L10n.Settings.Approvals.deny, Color.Bandito.danger)
        }
        return Text(text)
            .font(BanditoFont.text(size: 12, weight: 600))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(tint.opacity(0.1), in: Capsule())
    }

    private func scopeName(_ agentId: String?, server: ServerModel) -> String {
        guard let agentId else { return L10n.Settings.Approvals.allAgents }
        return server.agents.first { $0.id == agentId }?.name ?? agentId
    }

    private func reload(_ server: ServerModel?) async {
        guard let server, server.info != nil, server.supports("rules") else { return }
        do {
            rules = try await server.rules()
            error = nil
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    private func add(_ server: ServerModel) {
        let text = pattern.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            do {
                try await server.setRule(pattern: text, action: action, agentId: scope == "*" ? nil : scope)
                pattern = ""
                await reload(server)
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    private func delete(_ rule: Rule, server: ServerModel) async {
        do {
            try await server.deleteRule(rule.id)
            await reload(server)
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}
