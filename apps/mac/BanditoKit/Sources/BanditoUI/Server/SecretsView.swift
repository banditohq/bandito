import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server → Secrets: names, the last four characters, and which agents get each one. Values are write-only.
struct SecretsView: View {
    let server: ServerModel?
    @State private var secrets: [SecretInfo] = []
    @State private var error: UserFacingMessage?
    @State private var editing: SecretDraft?
    @State private var deleting: SecretInfo?

    var body: some View {
        ServerPage(
            title: L10n.Mode.serverSecrets,
            trailing: {
                if let server, server.supports("secrets") {
                    Button(L10n.Secrets.add) { editing = .new() }
                        .banditoButton(.signal())
                }
            }
        ) {
            if let server, server.supports("secrets") {
                Text(L10n.Secrets.hint)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                ServerCard {
                    HStack(spacing: 12) {
                        header(L10n.Secrets.columnName).frame(maxWidth: .infinity, alignment: .leading)
                        header(L10n.Secrets.columnValue).frame(width: 110, alignment: .leading)
                        header(L10n.Secrets.columnAgents).frame(width: 200, alignment: .leading)
                        Color.clear.frame(width: 64)
                    }
                    if secrets.isEmpty {
                        Text(L10n.Secrets.empty)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.Bandito.text2)
                            .padding(.vertical, 8)
                    }
                    ForEach(secrets) { secret in
                        HStack(spacing: 12) {
                            Text(secret.name)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color.Bandito.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.masked(secret.tail))
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(Color.Bandito.text3)
                                .frame(width: 110, alignment: .leading)
                            Text(Self.whoLabel(secret.agents, server: server))
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.Bandito.text2)
                                .lineLimit(1)
                                .frame(width: 200, alignment: .leading)
                            HStack(spacing: 4) {
                                Button {
                                    editing = .edit(secret, server: server)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .banditoButton(.icon(size: 26, label: L10n.Secrets.editAria(name: secret.name)))
                                Button {
                                    deleting = secret
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .banditoButton(.icon(size: 26, label: L10n.Secrets.deleteAria(name: secret.name)))
                            }
                            .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                        .overlay(alignment: .top) { Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1) }
                    }
                    if let error {
                        UserFacingErrorView(message: error)
                    }
                }
            } else {
                ServerUnavailable(server: server)
            }
        }
        .task(id: server?.info != nil) {
            await reload()
        }
        .banditoSheet(item: $editing) { draft in
            if let server {
                SecretEditor(draft: draft, server: server) { await reload() }
            }
        }
        .confirmationDialog(
            L10n.Secrets.deleteTitle(name: deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { secret in
            Button(L10n.Common.delete, role: .destructive) {
                Task { await delete(secret) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Secrets.deleteMessage)
        }
    }

    private func header(_ text: String) -> some View {
        SectionLabel(text)
    }

    private func reload() async {
        guard let server, server.info != nil, server.supports("secrets") else { return }
        do {
            secrets = try await server.secrets()
            error = nil
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    private func delete(_ secret: SecretInfo) async {
        guard let server else { return }
        do {
            try await server.deleteSecret(name: secret.name)
            await reload()
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    /// "••••" followed by the last four characters; just the dots for a short value.
    static func masked(_ tail: String) -> String {
        "••••\(tail)"
    }

    /// Who gets a secret: everyone, nobody, or the names of the agents.
    static func whoLabel(_ agents: [String], server: ServerModel?) -> String {
        if agents.contains("*") { return L10n.Secrets.allAgents }
        if agents.isEmpty { return L10n.Secrets.nobody }
        return agents.map { id in server?.agents.first { $0.id == id }?.name ?? id }.joined(separator: ", ")
    }
}

/// The add and edit sheet. The value is never shown again: editing asks for it anew.
struct SecretDraft: Identifiable {
    var id: String { isNew ? "new" : name }
    var isNew: Bool
    var name: String
    var value = ""
    var allAgents: Bool
    var agentIDs: Set<String>

    static func new() -> SecretDraft {
        SecretDraft(isNew: true, name: "", allAgents: false, agentIDs: [])
    }

    static func edit(_ secret: SecretInfo, server: ServerModel) -> SecretDraft {
        SecretDraft(
            isNew: false, name: secret.name, allAgents: secret.agents.contains("*"),
            agentIDs: Set(secret.agents.filter { $0 != "*" }))
    }
}

private struct SecretEditor: View {
    @State var draft: SecretDraft
    let server: ServerModel
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: UserFacingMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.isNew ? L10n.Secrets.addTitle : L10n.Secrets.editTitle(name: draft.name))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            field(L10n.Secrets.nameLabel) {
                TextField(L10n.Secrets.namePlaceholder, text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .disabled(!draft.isNew)
                if !draft.name.isEmpty && !SecretRules.isValidName(draft.name) {
                    Text(L10n.Secrets.nameRule)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Bandito.danger)
                }
            }
            field(L10n.Secrets.valueLabel) {
                SecureField(draft.isNew ? "" : L10n.Secrets.reenter, text: $draft.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                Text(L10n.Secrets.valueHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
            }
            field(L10n.Secrets.agentsLabel) {
                Toggle(L10n.Secrets.allAgents, isOn: $draft.allAgents)
                    .toggleStyle(BanditoToggleStyle())
                ForEach(server.agents) { agent in
                    Toggle(agent.name, isOn: Binding(
                        get: { draft.agentIDs.contains(agent.id) },
                        set: { on in
                            if on { draft.agentIDs.insert(agent.id) } else { draft.agentIDs.remove(agent.id) }
                        }))
                    .toggleStyle(BanditoToggleStyle())
                    .disabled(draft.allAgents)
                }
            }
            if let error {
                UserFacingErrorView(message: error)
            }
            HStack {
                Spacer()
                Button(L10n.Common.cancel) { dismiss() }
                    .banditoButton(.quiet())
                Button(L10n.Common.save) { save() }
                    .banditoButton(.signal())
                    .disabled(!canSave || saving)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color.Bandito.surface2)
    }

    private var canSave: Bool {
        SecretRules.isValidName(draft.name) && SecretRules.isValidValue(draft.value)
    }

    private func save() {
        let agents = draft.allAgents ? ["*"] : draft.agentIDs.sorted()
        saving = true
        error = nil
        Task {
            do {
                try await server.setSecret(name: draft.name, value: draft.value, agents: agents)
                await onSaved()
                dismiss()
            } catch {
                self.error = UserFacingError.message(for: error)
            }
            saving = false
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            content()
        }
    }
}
