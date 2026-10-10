import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// "Своя интеграция": adds an MCP server that is not in the catalog. The owner pastes what the server's documentation
/// shows (a Claude Desktop or Cursor config, one server's object, a command, or a URL) and the fields fill themselves;
/// or fills them by hand. "Check" tries the connection before the owner commits. A daemon with `integrations_probe`
/// tries the draft and saves nothing. An older daemon adds the server turned off, and leaving the sheet without "Add"
/// takes it away again, with the secrets the sheet wrote.
struct CustomIntegrationSheet: View {
    let server: ServerModel
    let existingNames: [String]
    var onChecked: (String, IntegrationTest) -> Void
    var onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = IntegrationDraft.custom(kind: .stdio)
    @State private var pasted = ""
    @State private var recognition: Recognition = .none
    /// Several servers found in one config, and which of them the owner ticked.
    @State private var found: [ParsedServer] = []
    @State private var chosen: Set<Int> = []
    /// Ticked servers still to add after the one in the form.
    @State private var queue: [ParsedServer] = []
    @State private var editingName = false
    @State private var attempted = false
    @State private var busy = false
    @State private var checking = false
    @State private var test: IntegrationTest?
    @State private var error: UserFacingMessage?
    /// The secrets this sheet wrote, to take away again when the sheet is left without "Add".
    @State private var writtenSecrets: [String] = []
    /// "Add" went through: the integration stays when the sheet closes.
    @State private var finished = false
    /// "Check" was pressed: the note about the trial shows under the buttons from then on.
    @State private var checkAsked = false

    /// What the paste field made of its text.
    enum Recognition: Equatable {
        case none
        case program(String)
        case web(String)
        case many(Int)
        case failed(ConfigParseFailure)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.Integrations.addOwn)
                .font(BanditoFont.display(size: 18.5, weight: 600))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.Bandito.text)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pasteZone
                    manualDivider
                    nameField
                    kindCards
                    kindFields
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 560)

            feedback
            buttons
            if let test {
                IntegrationTestResult(result: test)
            }
            if checkAsked, !probes {
                Text(L10n.Integrations.Custom.trialNote)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Color.Bandito.surface2)
        .onDisappear { discardTrial() }
    }

    // MARK: - paste

    private var pasteZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Integrations.Custom.paste)
                .font(BanditoFont.text(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $pasted)
                    .font(BanditoFont.mono(size: 12.5, weight: 400))
                    .banditoEditor()
                if pasted.isEmpty {
                    // Two lines, both in the monospaced face. The padding is the field's own plus the editor's inset.
                    Text(L10n.Integrations.Custom.pastePlaceholder)
                        .font(BanditoFont.mono(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 108)
            .onChange(of: pasted) { _, text in read(text) }
            recognitionLine
            if found.count > 1 {
                foundList
            }
        }
    }

    @ViewBuilder
    private var recognitionLine: some View {
        switch recognition {
        case .none:
            EmptyView()
        case .program(let command):
            Label {
                Text(L10n.Integrations.Custom.recognizedProgram(command: command)).lineLimit(2)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.ok)
        case .web(let url):
            Label {
                Text(L10n.Integrations.Custom.recognizedWeb(url: url)).lineLimit(2)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.ok)
        case .many(let count):
            Label {
                Text(L10n.Integrations.Custom.recognizedMany(count: count))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.ok)
        case .failed(let failure):
            Label {
                Text(L10n.Integrations.Custom.failed(reason: Self.reason(failure)))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(BanditoFont.text(size: 12.5, weight: 500))
            .foregroundStyle(Color.Bandito.danger)
        }
    }

    private var foundList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(found.enumerated()), id: \.offset) { index, server in
                Toggle(isOn: Binding(
                    get: { chosen.contains(index) },
                    set: { on in if on { chosen.insert(index) } else { chosen.remove(index) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.name ?? "—")
                            .font(BanditoFont.text(size: 13, weight: 500))
                            .foregroundStyle(Color.Bandito.text)
                        Text(summary(of: server))
                            .font(BanditoFont.mono(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Button(L10n.Integrations.Custom.useSelected(count: chosen.count), action: useChosen)
                .banditoButton(.quiet())
                .disabled(chosen.isEmpty)
                .fixedSize()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.Bandito.surface1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.Bandito.line))
    }

    private var manualDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            Text(L10n.Integrations.Custom.manual)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize()
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
        }
    }

    // MARK: - manual

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            label(L10n.Integrations.Custom.titleLabel)
            TextField(
                L10n.Integrations.Custom.titlePlaceholder,
                text: Binding(
                    get: { draft.title },
                    set: { draft.setTitle($0, existingNames: existingNames) }))
                .banditoField()
                .font(BanditoFont.text(size: 13, weight: 400))
            if editingName {
                TextField(
                    L10n.Integrations.Sheet.name,
                    text: Binding(get: { draft.name }, set: { draft.setName($0) })
                )
                .banditoField()
                .font(BanditoFont.mono(size: 12.5, weight: 400))
                .onSubmit { editingName = false }
                Text(L10n.Integrations.Sheet.nameHint)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            } else if !draft.name.isEmpty {
                Button { editingName = true } label: {
                    Text(L10n.Integrations.Custom.willBe(name: draft.name))
                        .font(BanditoFont.mono(size: 11.5, weight: 400))
                }
                .banditoButton(.link)
                .help(L10n.Integrations.Custom.editName)
                .fixedSize()
            }
        }
    }

    private var kindCards: some View {
        HStack(spacing: 10) {
            kindCard(
                .stdio, symbol: "terminal", title: L10n.Integrations.Custom.kindProgram,
                caption: L10n.Integrations.Custom.kindProgramHint)
            kindCard(
                .http, symbol: "network", title: L10n.Integrations.Custom.kindWeb,
                caption: L10n.Integrations.Custom.kindWebHint)
        }
    }

    private func kindCard(_ kind: IntegrationKind, symbol: String, title: String, caption: String) -> some View {
        let selected = draft.kind == kind
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            select(kind)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text2)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.Bandito.text.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BanditoFont.text(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(caption)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? Color.Bandito.surface2 : Color.Bandito.surface1))
            .overlay(
                shape.strokeBorder(
                    selected ? Color.Bandito.text : Color.Bandito.text.opacity(0.06),
                    lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .banditoButton(.row(cornerRadius: 12))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var kindFields: some View {
        switch draft.kind {
        case .stdio:
            VStack(alignment: .leading, spacing: 6) {
                label(L10n.Integrations.Custom.commandLine)
                TextField("npx -y @scope/package", text: $draft.commandLine, axis: .vertical)
                    .lineLimit(1...4)
                    .banditoField()
                    .font(BanditoFont.mono(size: 12.5, weight: 400))
                Text(L10n.Integrations.Custom.commandHint)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            pairs(L10n.Integrations.Custom.variables, items: $draft.env)
        case .http:
            VStack(alignment: .leading, spacing: 6) {
                label(L10n.Integrations.Sheet.url)
                TextField("https://…", text: $draft.url)
                    .banditoField()
                    .font(BanditoFont.mono(size: 12.5, weight: 400))
                Text(L10n.Integrations.Sheet.urlHint)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            pairs(L10n.Integrations.Sheet.headers, items: $draft.headers)
        }
    }

    private func pairs(_ title: String, items: Binding<[IntegrationPair]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title)
            ForEach(items) { $pair in
                IntegrationPairRow(pair: $pair) {
                    items.wrappedValue.removeAll { $0.id == pair.id }
                }
            }
            Button {
                items.wrappedValue.append(IntegrationPair())
            } label: {
                Label(L10n.Integrations.Custom.add, systemImage: "plus")
            }
            .banditoButton(.link)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.text(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
    }

    // MARK: - feedback and buttons

    @ViewBuilder
    private var feedback: some View {
        if let problem = currentProblem, attempted {
            Text(IntegrationEditor.text(problem))
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error {
            UserFacingErrorView(message: error, onRetry: { add() })
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if !queue.isEmpty {
                Text(L10n.Integrations.Custom.remaining(count: queue.count))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Spacer(minLength: 8)
            Button(L10n.Common.cancel) { dismiss() }
                .banditoButton(.quiet())
                .fixedSize()
            Button(checking ? L10n.Integrations.checking : L10n.Integrations.check) { check() }
                .banditoButton(.quiet())
                .disabled(busy || checking)
                .fixedSize()
            Button(L10n.Integrations.Custom.add) { add() }
                .banditoButton(.signal())
                .keyboardShortcut(.defaultAction)
                .disabled(busy || checking)
                .fixedSize()
        }
    }

    private var currentProblem: IntegrationDraft.Problem? {
        draft.problem(existingNames: existingNames)
    }

    // MARK: - reading the paste

    private func read(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recognition = .none
            found = []
            chosen = []
            return
        }
        switch MCPConfigParser.parse(text) {
        case .failure(let failure):
            recognition = .failed(failure)
            found = []
            chosen = []
        case .servers(let servers) where servers.count == 1:
            found = []
            chosen = []
            fill(servers[0])
        case .servers(let servers):
            found = servers
            chosen = Set(servers.indices)
            recognition = .many(servers.count)
        }
    }

    private func fill(_ server: ParsedServer) {
        draft.apply(server, existingNames: existingNames)
        recognition = server.kind == .stdio ? .program(server.commandLine) : .web(server.url)
        test = nil
        error = nil
        attempted = false
    }

    /// Takes the ticked servers: the first goes into the form, the rest wait their turn after "Add".
    private func useChosen() {
        let picked = chosen.sorted().map { found[$0] }
        guard let first = picked.first else { return }
        queue = Array(picked.dropFirst())
        found = []
        chosen = []
        fill(first)
    }

    private func summary(of server: ParsedServer) -> String {
        server.kind == .stdio ? server.commandLine : server.url
    }

    private func select(_ kind: IntegrationKind) {
        guard draft.kind != kind else { return }
        draft.kind = kind
        // The variables belong to a program and the headers to an address: the other list would only be dead weight.
        if kind == .http { draft.env = [] } else { draft.headers = [] }
        test = nil
    }

    static func reason(_ failure: ConfigParseFailure) -> String {
        switch failure {
        case .empty, .noServers: L10n.Integrations.Custom.Reason.noServers
        case .invalidJSON: L10n.Integrations.Custom.Reason.json
        case .unclosedQuote: L10n.Integrations.Custom.Reason.quote
        case .notACommand(let word): L10n.Integrations.Custom.Reason.command(word: word)
        }
    }

    // MARK: - actions

    /// Whether the daemon can try a draft without saving it (`integrations_probe`). Older daemons get the trial below.
    private var probes: Bool { server.supports("integrations_probe") }

    /// "Check": with the daemon's probe, tries the draft as it stands and saves nothing. An older daemon has no probe:
    /// the server is added turned off (once), then tried.
    private func check() {
        attempted = true
        checkAsked = true
        error = nil
        guard currentProblem == nil else { return }
        if probes {
            probeDraft()
            return
        }
        busy = true
        Task {
            defer { busy = false }
            guard let id = await persist(enabled: draft.editingID == nil ? false : nil) else { return }
            await runCheck(id)
        }
    }

    /// "Check" with the daemon's probe: the result shows under the buttons, and nothing is written.
    private func probeDraft() {
        checking = true
        Task {
            defer { checking = false }
            do {
                test = try await server.probeIntegration(draft.probeDraft())
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    /// "Add": the server stays, turned on. With ticked servers waiting, the next one goes into the form.
    private func add() {
        attempted = true
        error = nil
        guard currentProblem == nil else { return }
        busy = true
        Task {
            defer { busy = false }
            guard await persist(enabled: true) != nil else { return }
            finished = true
            await onSaved()
            if queue.isEmpty {
                dismiss()
            } else {
                next()
            }
        }
    }

    /// The form again, for the next ticked server.
    private func next() {
        let server = queue.removeFirst()
        draft = .custom(kind: .stdio)
        pasted = ""
        recognition = .none
        test = nil
        error = nil
        attempted = false
        editingName = false
        writtenSecrets = []
        finished = false
        fill(server)
    }

    /// Writes the draft to the server: the integration, and its secrets. A new secret never overwrites someone else's.
    /// Returns the integration's id, or nil when something failed (the error is shown, with a retry).
    private func persist(enabled: Bool?) async -> String? {
        do {
            let taken = Set(try await server.secrets().map(\.name))
            draft.assignSecretNames(taken: taken)
            let save = draft.build(enabled: enabled)
            if let id = draft.editingID {
                guard await writeSecrets(save.secrets) else { return nil }
                if let patch = save.patch {
                    try await server.updateIntegration(id, patch: patch)
                }
                return id
            }
            guard let create = save.create else { return nil }
            let created = try await server.addIntegration(create)
            draft.markSaved(id: created.id)
            guard await writeSecrets(save.secrets) else { return nil }
            return created.id
        } catch {
            self.error = UserFacingError.message(for: error)
            return nil
        }
    }

    private func writeSecrets(_ writes: [IntegrationSecretWrite]) async -> Bool {
        do {
            for write in writes {
                try await server.setSecret(name: write.name, value: write.value, agents: write.agents)
                if !writtenSecrets.contains(write.name) { writtenSecrets.append(write.name) }
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

    /// Leaving the sheet without "Add": the server that "Check" added, and the secrets this sheet wrote, go away.
    private func discardTrial() {
        guard !finished, let id = draft.editingID else { return }
        let server = server
        let secrets = writtenSecrets
        let saved = onSaved
        Task {
            _ = try? await server.removeIntegration(id)
            for name in secrets { _ = try? await server.deleteSecret(name: name) }
            await saved()
        }
    }
}

/// The outcome of a check: the tools found, or what went wrong, with the server's own words under it.
struct IntegrationTestResult: View {
    let result: IntegrationTest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.ok {
                Text(L10n.Integrations.toolsFound(names: result.tools.joined(separator: ", ")))
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.ok)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(IntegrationFailureText.text(IntegrationFailure.classify(result.error)))
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if let raw = result.error, !raw.isEmpty {
                    Text(raw)
                        .font(BanditoFont.mono(size: 11, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(6)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
