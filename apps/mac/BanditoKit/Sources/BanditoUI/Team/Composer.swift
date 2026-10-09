import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The message box under the thread. Enter sends, Shift+Enter starts a new line. While a turn runs,
/// the send button becomes Stop (⌘. is the menu command, see `BanditoCommands`).
///
/// Typing `/` at the start opens the slash menu (see `SlashMenuView`). Built-in commands run in the app,
/// server and Mac commands are sent as `/name args`, and snippets are inserted into the draft.
struct Composer: View {
    @Binding var draft: String
    var agentName: String
    var running: Bool
    /// Share of the context window in use, 0 to 1.
    var contextFraction: Double
    /// The agent and its server, for slash commands. Without them the slash menu is off.
    var agent: Agent?
    var server: ServerModel?
    var onSend: () -> Void
    var onStop: () -> Void

    @Environment(Router.self) private var router
    @FocusState private var focused: Bool
    @State private var slash = SlashMenuModel()

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The typed command name while the menu is open, `nil` when it is closed.
    private var query: String? {
        guard agent != nil, !slash.suppressed else { return nil }
        return SlashTrigger.query(for: draft)
    }

    private var entries: [SlashEntry] {
        query.map { slash.entries(query: $0) } ?? []
    }

    var body: some View {
        @Bindable var model = slash
        VStack(spacing: 8) {
            if query != nil {
                SlashMenuView(
                    entries: entries, model: slash,
                    onRun: { entry in
                        slash.index = entries.firstIndex(of: entry) ?? 0
                        run(entry)
                    },
                    onNewSnippet: { slash.editingSnippet = true })
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if let notice = slash.notice {
                UserFacingErrorView(message: notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            HStack(alignment: .bottom, spacing: 10) {
                // Attaching files returns with uploads; a name-only "@file" was misleading.

                TextField(L10n.Thread.placeholder(name: agentName), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 14.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.vertical, 8)
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape]) { press in
                        handleMenuKey(press.key)
                    }
                    .onKeyPress(keys: [.return]) { press in
                        // Shift+Return is left to the field, which inserts a line break.
                        if press.modifiers.contains(.shift) { return .ignored }
                        if query != nil, entries.indices.contains(slash.index) {
                            run(entries[slash.index])
                            return .handled
                        }
                        if canSend && !running { submit() }
                        return .handled
                    }

                contextIndicator
                    .padding(.bottom, 9)

                sendOrStop
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)

            HStack(spacing: 14) {
                Text(L10n.Thread.hintSend)
                Text(L10n.Thread.hintNewLine)
                Text(L10n.Thread.hintStop)
                Text(L10n.Thread.hintSearch)
            }
            .font(BanditoFont.font(size: 11, weight: 400, mono: true))
            .foregroundStyle(Color.Bandito.text3.opacity(0.7))
        }
        .animation(.easeOut(duration: BanditoMotion.fast), value: query != nil)
        .onAppear { focused = true }
        .tourAnchor(.composer)
        .onChange(of: router.composerFocusAgentID, initial: true) { _, _ in
            guard let agentID = agent?.id else { return }
            if router.takeComposerFocus(agentID: agentID) { focused = true }
        }
        .onChange(of: draft) { _, _ in
            slash.suppressed = false
            slash.notice = nil
            slash.index = 0
        }
        .task(id: agent?.id) {
            guard let agent, let server else { return }
            await slash.loadServerCommands(server: server, agentID: agent.id)
        }
        .task {
            await slash.loadMacCommands()
        }
        .banditoSheet(isPresented: $model.editingSnippet) {
            SnippetEditor { snippet in slash.saveSnippet(snippet) }
        }
        .confirmationDialog(
            L10n.Slash.installTitle(name: slash.pendingInstall?.name ?? ""),
            isPresented: Binding(
                get: { slash.pendingInstall != nil },
                set: { if !$0 { slash.pendingInstall = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Slash.installConfirm) { installPendingAndSend() }
            Button(L10n.Common.cancel, role: .cancel) { slash.pendingInstall = nil }
        } message: {
            Text(L10n.Slash.installMessage)
        }
    }

    private var contextIndicator: some View {
        HStack(spacing: 6) {
            ContextRing(fraction: contextFraction, size: 16)
            Text("\(Int((contextFraction * 100).rounded()))%")
                .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
        }
        .foregroundStyle(Color.Bandito.text3)
        .help(L10n.Composer.contextHint)
    }

    @ViewBuilder
    private var sendOrStop: some View {
        if running {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.Bandito.bg)
                    .frame(width: 34, height: 34)
                    .background(Color.Bandito.text, in: Circle())
            }
            .banditoButton(.brighten)
            .help(L10n.Thread.stop)
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.Bandito.bg)
                    .frame(width: 34, height: 34)
                    .background(Color.Bandito.text, in: Circle())
            }
            .banditoButton(.brighten)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .help(L10n.Thread.send)
        }
    }

    // MARK: Keys and menu actions

    private func handleMenuKey(_ key: KeyEquivalent) -> KeyPress.Result {
        guard query != nil else { return .ignored }
        switch key {
        case .upArrow:
            slash.index = max(0, slash.index - 1)
        case .downArrow:
            slash.index = min(max(entries.count - 1, 0), slash.index + 1)
        case .tab:
            guard entries.indices.contains(slash.index) else { return .handled }
            complete(entries[slash.index])
        case .escape:
            slash.suppressed = true
        default:
            return .ignored
        }
        return .handled
    }

    /// Tab: finish the name in the field. A command that takes arguments waits for them; a snippet is inserted.
    private func complete(_ entry: SlashEntry) {
        if entry.origin == .mine {
            run(entry)
            return
        }
        let takesArgs = !(entry.argsHint ?? "").isEmpty
        draft = "/" + entry.name + (takesArgs ? " " : "")
        focused = true
    }

    /// Enter on a menu row. Snippets are inserted; commands with arguments are completed; the rest run.
    private func run(_ entry: SlashEntry) {
        if entry.origin == .mine {
            guard let snippet = slash.snippets.first(where: { $0.name == entry.name }) else { return }
            draft = SnippetTemplate.insert(snippet.text, into: "").text
            focused = true
            return
        }
        if !(entry.argsHint ?? "").isEmpty {
            complete(entry)
            return
        }
        draft = "/" + entry.name
        submit()
    }

    /// Enter or the send button. Built-in commands run here; a Mac command that the server lacks waits for
    /// the install prompt; everything else is sent as typed.
    private func submit() {
        guard let agent, let server else {
            onSend()
            return
        }
        if let invocation = SlashInvocationParser.parse(draft) {
            if let builtin = BuiltinSlash.named(invocation.name) {
                runBuiltin(builtin, args: invocation.args, agent: agent, server: server)
                return
            }
            if slash.macCommandToInstall(named: invocation.name) != nil {
                slash.pendingInstall = slash.macCommandToInstall(named: invocation.name)
                return
            }
        }
        onSend()
    }

    private func runBuiltin(_ command: BuiltinSlash, args: String, agent: Agent, server: ServerModel) {
        switch command {
        case .new:
            draft = ""
            router.sheet = .newAgent
        case .model:
            guard !args.isEmpty else {
                slash.notice = UserFacingMessage(text: L10n.Slash.modelNeedsName)
                return
            }
            draft = ""
            perform { try await server.updateAgent(agent.id, model: args) }
        case .effort:
            guard let level = BuiltinSlash.effortLevel(from: args) else {
                slash.notice = UserFacingMessage(text: L10n.Slash.effortInvalid)
                return
            }
            guard agent.runtime.supportedEfforts.contains(level) else {
                slash.notice = UserFacingMessage(text: L10n.Slash.effortUnsupported(runtime: agent.runtime.rawValue, level: level.rawValue))
                return
            }
            draft = ""
            perform { try await server.updateAgent(agent.id, effort: level) }
        case .pause:
            draft = ""
            perform { try await server.setPaused(agentID: agent.id, !agent.paused) }
        case .memory:
            draft = ""
            router.openInspector(.memory)
        case .changes:
            draft = ""
            router.sheet = .changes(agentID: agent.id)
        case .terminal:
            draft = ""
            router.pendingTerminalCwd = agent.cwd
            router.select(mode: .terminals)
        case .files:
            draft = ""
            router.filesPath = agent.cwd
            router.select(mode: .files)
        case .usage:
            draft = ""
            router.usagePopoverOpen = true
        }
    }

    /// Installs the Mac command the person agreed to, then sends the message that named it.
    private func installPendingAndSend() {
        guard let command = slash.pendingInstall, let server, let agent else { return }
        slash.pendingInstall = nil
        Task {
            do {
                try await server.installCommand(CommandInstallRequest.user(command))
                await slash.loadServerCommands(server: server, agentID: agent.id)
                onSend()
            } catch {
                slash.notice = UserFacingError.message(for: error)
            }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                slash.notice = UserFacingError.message(for: error)
            }
        }
    }

    /// Until uploads exist, an attached file is referred to by its name: the file path goes into the text as `@name`.
    private func attachFile() {
        guard let url = FilePanels.openURL() else { return }
        let separator = draft.isEmpty || draft.hasSuffix(" ") ? "" : " "
        draft += "\(separator)@\(url.lastPathComponent) "
        focused = true
    }
}
