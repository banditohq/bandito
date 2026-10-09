import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Approvals: rules for what agents may do without asking, and the checks the daemon always runs.
struct ApprovalsSection: View {
    @Environment(AppModel.self) private var app
    @State private var rules: [Rule] = []
    @State private var pattern = ""
    @State private var action: RuleAction = .ask
    /// "*" for every agent, otherwise an agent id.
    @State private var scope = "*"
    @State private var error: String?

    /// Checks the daemon runs on every server (docs/ARCHITECTURE.md#approvals-policy). Shown, not editable.
    private static let builtin = [
        "git push*", "git reset --hard*", "rm -rf*", "*deploy*", "npm publish*", "cargo publish*",
        "kubectl delete*", "terraform apply*", "*drop table*", "docker system prune*",
    ]

    var body: some View {
        let server = app.currentServer
        SettingsPage(title: SettingsSection.approvals.title, intro: L10n.Settings.Approvals.intro) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let server, server.supports("rules") {
                        newRule(server)
                        rulesTable(server)
                    } else {
                        Text(L10n.Server.updateNote)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.Bandito.text2)
                    }
                    builtinChecks
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .task(id: server?.info != nil) {
            await reload(server)
        }
    }

    private func newRule(_ server: ServerModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Settings.Approvals.newRule)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            HStack(alignment: .bottom, spacing: 10) {
                labeled(L10n.Settings.Approvals.when) {
                    TextField(L10n.Settings.Approvals.patternPlaceholder, text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .onSubmit { add(server) }
                }
                .frame(maxWidth: .infinity)
                labeled(L10n.Settings.Approvals.then) {
                    Picker("", selection: $action) {
                        Text(L10n.Settings.Approvals.allow).tag(RuleAction.allow)
                        Text(L10n.Settings.Approvals.ask).tag(RuleAction.ask)
                        Text(L10n.Settings.Approvals.deny).tag(RuleAction.deny)
                    }
                    .labelsHidden()
                }
                .frame(width: 150)
                labeled(L10n.Settings.Approvals.forWhom) {
                    Picker("", selection: $scope) {
                        Text(L10n.Settings.Approvals.allAgents).tag("*")
                        ForEach(server.agents) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                }
                .frame(width: 170)
                Button(L10n.Settings.Approvals.add) { add(server) }
                    .banditoButton(.lightPill())
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L10n.Settings.Approvals.wildcardNote)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.danger)
            }
        }
        .padding(14)
        .banditoCard()
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
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .padding(16)
            }
            ForEach(rules) { rule in
                HStack(spacing: 12) {
                    Text(rule.pattern)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    behaviorPill(rule.action)
                        .frame(width: 130, alignment: .leading)
                    Text(scopeName(rule.agentId, server: server))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    Button {
                        Task { await delete(rule, server: server) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .banditoButton(.icon(size: 26, label: L10n.Settings.Approvals.deleteAria(pattern: rule.pattern)))
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
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Self.builtin, id: \.self) { item in
                    chip(item, font: .system(size: 12, design: .monospaced), color: Color.Bandito.text2)
                }
                chip(L10n.Settings.Approvals.outsideProject, font: .system(size: 12), color: Color.Bandito.text2)
            }
            SectionLabel(L10n.Settings.Approvals.browserChecks)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(Self.browserChecks, id: \.self) { item in
                    chip(item, font: .system(size: 12), color: Color(hex: 0xA3BDEB))
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
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            content()
        }
    }

    private func chip(_ text: String, font: Font, color: Color) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
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
            .font(.system(size: 12, weight: .semibold))
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
            self.error = error.localizedDescription
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
                self.error = error.localizedDescription
            }
        }
    }

    private func delete(_ rule: Rule, server: ServerModel) async {
        do {
            try await server.deleteRule(rule.id)
            await reload(server)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
