import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The sheet that connects a catalog template, adds an own integration, or edits one. Saving writes the secrets first,
/// then the integration. A new integration is checked at once; after that the sheet edits it.
struct IntegrationEditor: View {
    let server: ServerModel
    let target: IntegrationTarget
    let existingNames: [String]
    var onChecked: (String, IntegrationTest) -> Void
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: IntegrationDraft
    @State private var catalogEntry: IntegrationCatalogEntry?
    @State private var attempted = false
    @State private var busy = false
    @State private var checking = false
    @State private var test: IntegrationTest?
    @State private var error: UserFacingMessage?

    init(
        server: ServerModel, target: IntegrationTarget, existingNames: [String],
        onChecked: @escaping (String, IntegrationTest) -> Void, onSaved: @escaping () async -> Void
    ) {
        self.server = server
        self.target = target
        self.existingNames = existingNames
        self.onChecked = onChecked
        self.onSaved = onSaved
        switch target {
        case .catalog(let entry):
            _draft = State(initialValue: .fromCatalog(entry))
            _catalogEntry = State(initialValue: entry)
        case .custom:
            // The own integration has its own sheet (CustomIntegrationSheet); this one never gets it.
            _draft = State(initialValue: .custom(kind: .stdio))
            _catalogEntry = State(initialValue: nil)
        case .edit(let integration):
            _draft = State(initialValue: .editing(integration))
            _catalogEntry = State(initialValue: nil)
        }
    }

    /// A draft that the daemon already has: it is edited, and can be checked.
    private var isSaved: Bool { draft.editingID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            if let catalogEntry {
                Text(catalogEntry.description(languageCode: ModelDescription.currentLanguageCode))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if catalogEntry.id == "composio" {
                    Text(L10n.Integrations.Sheet.composioHint)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: catalogEntry.docsUrl) {
                    Link(L10n.Integrations.Sheet.docs, destination: url)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.Bandito.info)
                        .fixedSize()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fields
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 460)

            if let problem = currentProblem, attempted {
                Text(Self.text(problem))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let test {
                IntegrationTestResult(result: test)
            }
            if let error {
                UserFacingErrorView(message: error, onRetry: { save() })
            }
            HStack(spacing: 10) {
                Spacer(minLength: 8)
                Button(L10n.Common.cancel) { dismiss() }
                    .banditoButton(.quiet())
                    .fixedSize()
                if isSaved, let id = draft.editingID {
                    Button(checking ? L10n.Integrations.checking : L10n.Integrations.check) {
                        Task { await runCheck(id) }
                    }
                    .banditoButton(.quiet())
                    .disabled(checking)
                    .fixedSize()
                }
                if isNewAndChecked {
                    Button(L10n.Common.close) { dismiss() }
                        .banditoButton(.signal())
                        .fixedSize()
                } else {
                    Button(isSaved ? L10n.Common.save : L10n.Integrations.connect) { save() }
                        .banditoButton(.signal())
                        .disabled(busy)
                        .fixedSize()
                }
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Color.Bandito.surface2)
    }

    /// Once a new integration is saved and checked, the sheet has nothing left to save: it offers only to close.
    private var isNewAndChecked: Bool { isSaved && test != nil && target.isNew }

    private var title: String {
        switch target {
        case .catalog(let entry): L10n.Integrations.Sheet.connectTitle(name: entry.name)
        case .custom: L10n.Integrations.addOwn
        case .edit(let integration): L10n.Integrations.Sheet.editTitle(name: integration.name)
        }
    }

    private var currentProblem: IntegrationDraft.Problem? {
        draft.problem(existingNames: existingNames)
    }

    // MARK: - fields

    @ViewBuilder
    private var fields: some View {
        field(L10n.Integrations.Sheet.name, hint: L10n.Integrations.Sheet.nameHint) {
            TextField(L10n.Integrations.Sheet.name, text: $draft.name)
                .banditoField()
                .font(BanditoFont.font(size: 13, weight: 400, mono: true))
        }
        switch draft.kind {
        case .stdio:
            field(L10n.Integrations.Custom.commandLine, hint: L10n.Integrations.Custom.commandHint) {
                TextField(L10n.Integrations.Custom.commandLine, text: $draft.commandLine, axis: .vertical)
                    .lineLimit(1...4)
                    .banditoField()
                    .font(BanditoFont.font(size: 13, weight: 400, mono: true))
            }
        case .http:
            field(L10n.Integrations.Sheet.url, hint: L10n.Integrations.Sheet.urlHint) {
                TextField(catalogEntry?.urlHint ?? L10n.Integrations.Sheet.urlHint, text: $draft.url)
                    .banditoField()
                    .font(BanditoFont.font(size: 13, weight: 400, mono: true))
            }
        }
        if !draft.headers.isEmpty || draft.kind == .http {
            pairs(L10n.Integrations.Sheet.headers, items: $draft.headers)
        }
        pairs(L10n.Integrations.Sheet.variables, items: $draft.env)
    }

    private func field<Content: View>(
        _ label: String, hint: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pairs(_ title: String, items: Binding<[IntegrationPair]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            ForEach(items) { $pair in
                IntegrationPairRow(pair: $pair) {
                    items.wrappedValue.removeAll { $0.id == pair.id }
                }
            }
            Button(L10n.Integrations.Sheet.addLine) {
                items.wrappedValue.append(IntegrationPair())
            }
            .banditoButton(.link)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - actions

    /// Saves the sheet. Secret names are checked against the server first, so a new secret never overwrites someone
    /// else's. A new integration is added first, then its secrets are written; a failed write keeps the sheet open
    /// with a retry, and the typed values stay in it.
    private func save() {
        attempted = true
        error = nil
        guard currentProblem == nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let taken = Set(try await server.secrets().map(\.name))
                draft.assignSecretNames(taken: taken)
                let save = draft.build()
                if let id = draft.editingID {
                    guard await writeSecrets(save.secrets) else { return }
                    if let patch = save.patch {
                        try await server.updateIntegration(id, patch: patch)
                    }
                    await onSaved()
                    if target.isNew {
                        await runCheck(id)
                    } else {
                        dismiss()
                    }
                } else if let create = save.create {
                    let created = try await server.addIntegration(create)
                    draft.markSaved(id: created.id)
                    attempted = false
                    await onSaved()
                    guard await writeSecrets(save.secrets) else { return }
                    await runCheck(created.id)
                }
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    /// Writes the secrets one by one. Returns false, with the retry shown, when one of them is not saved.
    private func writeSecrets(_ writes: [IntegrationSecretWrite]) async -> Bool {
        do {
            for write in writes {
                try await server.setSecret(name: write.name, value: write.value, agents: write.agents)
            }
            draft.markSecretsWritten()
            return true
        } catch {
            let technical = UserFacingError.message(for: error).text
            self.error = UserFacingMessage(
                text: L10n.Integrations.Sheet.secretNotSaved, technical: technical, canRetry: true)
            return false
        }
    }

    private func runCheck(_ id: String) async {
        checking = true
        defer { checking = false }
        do {
            let result = try await server.testIntegration(id)
            test = result
            onChecked(id, result)
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    static func text(_ problem: IntegrationDraft.Problem) -> String {
        switch problem {
        case .nameEmpty: L10n.Integrations.Problem.nameEmpty
        case .nameInvalid: L10n.Integrations.Problem.nameInvalid
        case .nameTaken: L10n.Integrations.Problem.nameTaken
        case .commandEmpty: L10n.Integrations.Problem.commandEmpty
        case .quoteUnclosed: L10n.Integrations.Problem.quoteUnclosed
        case .urlInvalid: L10n.Integrations.Problem.urlInvalid
        case .keyEmpty: L10n.Integrations.Problem.keyEmpty
        case .keyInvalid(let key): L10n.Integrations.Problem.keyInvalid(key: key)
        case .secretMissing(let key): L10n.Integrations.Problem.secretMissing(key: key)
        case .secretNameInvalid(let name): L10n.Integrations.Problem.secretNameInvalid(name: name)
        case .valueMissing(let key): L10n.Integrations.Problem.valueMissing(key: key)
        }
    }
}

extension IntegrationTarget {
    /// Whether the sheet connects an integration that does not exist yet.
    var isNew: Bool {
        if case .edit = self { return false }
        return true
    }
}

/// One line of variables or headers: the key, the value (or the secret typed in), and the switch that makes it a secret.
struct IntegrationPairRow: View {
    @Binding var pair: IntegrationPair
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(L10n.Integrations.Sheet.keyPlaceholder, text: $pair.key)
                    .banditoField()
                    .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
                    .frame(width: 130)
                if pair.isSecret {
                    SecureField(L10n.Integrations.Sheet.valuePlaceholder, text: $pair.value)
                        .banditoField()
                        .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
                } else {
                    TextField(L10n.Integrations.Sheet.valuePlaceholder, text: $pair.value)
                        .banditoField()
                        .font(BanditoFont.font(size: 12.5, weight: 400, mono: true))
                }
                if pair.template == nil {
                    Toggle(isOn: $pair.isSecret) {
                        Text(L10n.Integrations.Sheet.secret)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .toggleStyle(BanditoToggleStyle())
                    .fixedSize()
                }
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .banditoButton(.icon(size: 26, label: L10n.Integrations.remove))
                .help(L10n.Integrations.remove)
            }
            if pair.isSecret {
                Text(pair.storedSecret.map { L10n.Integrations.Sheet.storedSecret(name: $0) }
                    ?? L10n.Integrations.Sheet.secretHint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
