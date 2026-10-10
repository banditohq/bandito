import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The message box under the thread. Enter sends, Shift+Enter starts a new line. While a turn runs,
/// the send button becomes Stop (⌘. is the menu command, see `BanditoCommands`).
///
/// Typing `/` at the start opens the slash menu (see `SlashMenuView`). Built-in commands run in the app,
/// server and Mac commands are sent as `/name args`, and snippets are inserted into the draft.
///
/// Typing `@` after a space opens the mention menu (see `MentionMenuView`): services, teammates, files of the agent's
/// folder, open browser tabs. A pick leaves `@Label` in the text and a chip above the field; Backspace at the end of
/// the text takes a whole chip away. A service that is not connected asks "Connect X?" before the message goes.
struct Composer: View {
    @Binding var draft: String
    var agentName: String
    var running: Bool
    /// Share of the context window in use, 0 to 1.
    var contextFraction: Double
    /// The agent and its server, for slash commands. Without them the slash menu is off.
    var agent: Agent?
    var server: ServerModel?
    /// The message this one answers, shown in a bar above the field. Esc and the cross in the bar take it away.
    var reply: ReplyTarget?
    var onCancelReply: () -> Void = {}
    /// A form the agent waits on: the hint above the field, with a link that scrolls to the form (given its id).
    var waitingForm: FormRow?
    var onGoToForm: (String) -> Void = { _ in }
    var onSend: () -> Void
    var onStop: () -> Void
    /// Starts the agent's next chapter now (see `ServerModel.startNewChapter`). Shown only when the server supports it.
    var onNewChapter: () -> Void = {}
    /// The key hints under the field. The thread passes `false` once it has messages: the hints are for the empty thread.
    var showsHints: Bool = true

    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var slash = SlashMenuModel()
    @State private var mention = MentionMenuModel()
    /// The context popover is open (the ring is a button).
    @State private var showsContext = false
    /// The popover asks "start a new chapter?" before it does (reset when the popover closes).
    @State private var asksNewChapter = false
    private var canSend: Bool {
        AttachmentTray.canSend(text: draft, files: files)
    }

    /// The files waiting in this agent's composer.
    private var files: [DraftFile] {
        AttachmentTrays.shared.files(for: agent?.id ?? "")
    }

    /// Attaching needs an agent and a daemon that lists the `attachments` feature.
    private var canAttach: Bool {
        agent != nil && server?.supports("attachments") == true
    }

    /// The typed command name while the menu is open, `nil` when it is closed.
    private var query: String? {
        guard agent != nil, !slash.suppressed else { return nil }
        return SlashTrigger.query(for: draft)
    }

    private var entries: [SlashEntry] {
        query.map { slash.entries(query: $0) } ?? []
    }

    // MARK: Mentions

    private var agentID: String { agent?.id ?? "" }

    /// The mentions in this agent's draft.
    private var draftMentions: [DraftMention] { router.draftMentions[agentID] ?? [] }

    /// The `@word` being typed at the end of the draft; `nil` while the slash menu is open or Esc closed this one.
    private var mentionMatch: MentionTrigger.Match? {
        guard agent != nil, server != nil, !mention.suppressed, query == nil else { return nil }
        return MentionTrigger.match(in: draft)
    }

    private var mentionSections: [MentionSection] {
        guard let match = mentionMatch, let agent, let server else { return [] }
        return MentionSearch.sections(
            query: match.query, services: mention.services,
            agents: MentionSources.agents(server.agents, excluding: agent.id), files: mention.files,
            tabs: mention.tabs)
    }

    /// The menu has something to pick. With nothing to list it stays shut, so Enter sends as usual.
    private func mentionRows(_ sections: [MentionSection]) -> [MentionEntry] {
        MentionSearch.flatten(sections)
    }

    private func selectedMention(in rows: [MentionEntry]) -> MentionEntry? {
        rows.isEmpty ? nil : rows[min(max(mention.index, 0), rows.count - 1)]
    }

    var body: some View {
        @Bindable var model = slash
        @Bindable var mentionModel = mention
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
            let mentionSectionsNow = mentionSections
            let mentionRowsNow = mentionRows(mentionSectionsNow)
            if !mentionRowsNow.isEmpty {
                MentionMenuView(
                    sections: mentionSectionsNow, selectedKey: selectedMention(in: mentionRowsNow)?.key,
                    server: server, onPick: pickMention)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if let notice = slash.notice {
                UserFacingErrorView(message: notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            if let notice = mention.notice {
                UserFacingErrorView(message: notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            if let prompt = mention.connectPrompt, draftMentions.contains(where: { $0.pendingTemplate == prompt.pendingTemplate }) {
                connectBar(prompt)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if let waitingForm {
                formHint(waitingForm)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            if let reply {
                replyBar(reply)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            VStack(alignment: .leading, spacing: 8) {
                if !draftMentions.isEmpty {
                    MentionStrip(items: draftMentions, server: server, onRemove: removeMention)
                }
                if !files.isEmpty {
                    attachmentStrip
                }
                HStack(alignment: .bottom, spacing: 10) {
                    if canAttach {
                        attachMenu
                    }

                    TextField(L10n.Thread.placeholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(BanditoFont.text(size: 14.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .tint(Color.Bandito.signal)
                        .lineLimit(1...8)
                        .focused($focused)
                        .padding(.vertical, 8)
                        .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape]) { press in
                            handleMenuKey(press.key)
                        }
                        .onKeyPress(keys: [.delete]) { press in
                            handleBackspace(press)
                        }
                        .onKeyPress(keys: [KeyEquivalent("v")]) { press in
                            // ⌘V of a picture (and no text) attaches it. Text paste is left to the field.
                            guard canAttach, press.modifiers == .command, PictureSource.clipboardHoldsOnlyPicture,
                                let data = PictureSource.clipboardPNG(), let agent, let server
                            else { return .ignored }
                            AttachmentTrays.shared.addPicture(data, name: Self.pictureName("Clipboard"), agentID: agent.id, server: server)
                            return .handled
                        }
                        .onKeyPress(keys: [.return]) { press in
                            // Shift or Option with Return: a line break at the caret. Plain Return sends.
                            let newLine = ComposerReturn.action(
                                shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
                            if newLine == .newLine {
                                #if os(macOS)
                                FieldNewline.insert()
                                #endif
                                return .handled
                            }
                            if query != nil, entries.indices.contains(slash.index) {
                                run(entries[slash.index])
                                return .handled
                            }
                            if let picked = selectedMention(in: mentionRows(mentionSections)) {
                                pickMention(picked)
                                return .handled
                            }
                            if canSend && !running { submit() }
                            return .handled
                        }

                    contextIndicator
                        .padding(.bottom, 9)

                    sendOrStop
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(focused ? Color.Bandito.text.opacity(0.18) : Color.Bandito.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
            // In focus only: a faint signal glow around the whole field.
            .shadow(color: Color.Bandito.signal.opacity(focused ? 0.10 : 0), radius: 12)
            .banditoAnimation(.easeOut(duration: 0.18), value: focused)

            if showsHints {
                HStack(spacing: 14) {
                    Text(L10n.Thread.hintSend)
                    Text(L10n.Thread.hintNewLine)
                    Text(L10n.Thread.hintStop)
                    Text(L10n.Thread.hintSearch)
                }
                .font(BanditoFont.text(size: 11, weight: 400))
                .foregroundStyle(Color.Bandito.text3.opacity(0.7))
            }
        }
        .animation(.easeOut(duration: BanditoMotion.fast), value: query != nil)
        .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: reply)
        .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: waitingForm?.formId)
        .onAppear { takeFocus(.agentOpened) }
        .tourAnchor(.composer)
        .onChange(of: router.composerFocusAgentID, initial: true) { _, _ in
            guard let agentID = agent?.id else { return }
            if router.takeComposerFocus(agentID: agentID) { takeFocus(.requested) }
        }
        .onChange(of: mentionMatch?.query) { old, new in
            guard let agent, let server else { return }
            if let new {
                if old == nil { Task { await mention.opened(server: server, agent: agent) } }
                mention.updateFiles(query: new, server: server, agent: agent)
            } else {
                mention.closed()
            }
        }
        .onChange(of: agent?.id, initial: true) { _, id in
            // A connect belongs to the agent it was started for: going to another one drops it, and sends nothing.
            mention.agentID = id
            if mention.connecting != nil { mention.connecting = nil }
            if mention.connectPrompt != nil { mention.connectPrompt = nil }
            if mention.editing != nil { mention.editing = nil }
        }
        .onChange(of: app.oauth.phase) { _, phase in
            handleSignIn(phase)
        }
        .onChange(of: mention.editing) { old, new in
            if old != nil, new == nil { Task { await keyedServiceClosed() } }
        }
        .banditoSheet(item: $mentionModel.editing, dismissOnOutsideClick: false) { template in
            if let server {
                IntegrationEditor(
                    server: server, target: .catalog(template),
                    existingNames: MentionServices.shared.snapshot(for: server)?.integrations.map(\.name) ?? [],
                    onChecked: { _, _ in }, onSaved: { await MentionServices.shared.ensure(server, force: true) })
            }
        }
        .onChange(of: draft) { old, new in
            slash.suppressed = false
            slash.notice = nil
            slash.index = 0
            // Written only when they change: each write redraws the composer.
            if mention.suppressed { mention.suppressed = false }
            if mention.notice != nil { mention.notice = nil }
            if mention.index != 0 { mention.index = 0 }
            reconcileMentions()
            if SoundRules.isTypedCharacter(old: old, new: new) { SoundPlayer.play(.type) }
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

    /// Focuses the field when `ComposerFocus` allows it. Another text field being edited is told from the composer's
    /// own by the focus state: the field editor is first responder while `focused` is false.
    private func takeFocus(_ reason: ComposerFocus.Reason) {
        var other = false
        #if os(macOS)
        if !focused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor || editor.isEditable {
            other = true
        }
        #endif
        if ComposerFocus.shouldTakeFocus(reason: reason, otherFieldHasFocus: other) { focused = true }
    }

    /// The bar above the field: whom the message answers, and the first words of the original.
    private func replyBar(_ target: ReplyTarget) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.Bandito.signal)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.fromUser ? L10n.Reply.toSelf : L10n.Reply.toAgent(name: agentName))
                    .font(BanditoFont.text(size: 12, weight: 600))
                    .foregroundStyle(Color.Bandito.signal)
                    .lineLimit(1)
                Text(target.excerpt)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(action: onCancelReply) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .banditoButton(.icon(size: 24, label: L10n.Reply.cancel))
            .help(L10n.Reply.cancel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }

    /// The agent is waiting for an answer in a form: what to do, and a way to the form.
    private func formHint(_ form: FormRow) -> some View {
        HStack(spacing: 10) {
            StatusDot(status: .needsYou, size: 7, ringColor: Color.Bandito.signal.opacity(0.15))
            Text(L10n.Composer.formWaiting(name: agentName))
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Button {
                onGoToForm(form.formId)
            } label: {
                Text(L10n.Composer.formGo)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .banditoButton(.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.signal.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.Bandito.signal.opacity(0.3), lineWidth: 1))
    }

    private var contextIndicator: some View {
        let percent = Int((contextFraction * 100).rounded())
        return Button {
            showsContext.toggle()
        } label: {
            HStack(spacing: 6) {
                ContextRing(fraction: contextFraction, size: 16)
                Text("\(percent)%")
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .monospacedDigit()
            }
            .foregroundStyle(Color.Bandito.text3)
            .padding(.horizontal, 4)
            .frame(height: 22)
        }
        .banditoButton(.row(cornerRadius: 8))
        .help(L10n.Composer.contextHint)
        .popover(isPresented: $showsContext, arrowEdge: .top) {
            contextPopover(percent: percent)
        }
        .onChange(of: showsContext) { _, open in
            if !open { asksNewChapter = false }
        }
    }

    private func contextPopover(percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Composer.contextPopover(percent: "\(percent)"))
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            if server?.supportsNewChapter == true {
                if asksNewChapter {
                    Text(L10n.Composer.NewChapter.confirm)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button {
                            asksNewChapter = false
                        } label: {
                            Text(L10n.Common.cancel)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .banditoButton(.quiet())
                        Button {
                            showsContext = false
                            onNewChapter()
                        } label: {
                            Text(L10n.Composer.NewChapter.continue)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .banditoButton(.signal())
                    }
                } else {
                    Button {
                        asksNewChapter = true
                    } label: {
                        Text(L10n.Composer.NewChapter.button)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .banditoButton(.quiet())
                }
                if running {
                    Text(L10n.Composer.NewChapter.afterTurn)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: 280, alignment: .leading)
        .padding(14)
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
            // The button springs up from 0.9 when text appears, and settles back when the field is empty.
            .scaleEffect(canSend ? 1 : 0.9)
            .banditoAnimation(.spring(response: 0.25, dampingFraction: 0.6), value: canSend)
            .help(L10n.Thread.send)
        }
    }

    // MARK: Keys and menu actions

    private func handleMenuKey(_ key: KeyEquivalent) -> KeyPress.Result {
        // Esc with no menu open takes the reply away.
        if query == nil, key == .escape, reply != nil, mentionRows(mentionSections).isEmpty {
            onCancelReply()
            return .handled
        }
        let rows = mentionRows(mentionSections)
        if mentionMatch != nil, !rows.isEmpty {
            switch key {
            case .upArrow:
                mention.index = max(0, min(mention.index, rows.count - 1) - 1)
            case .downArrow:
                mention.index = min(rows.count - 1, mention.index + 1)
            case .tab:
                if let picked = selectedMention(in: rows) { pickMention(picked) }
            case .escape:
                mention.suppressed = true
            default:
                return .ignored
            }
            return .handled
        }
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
            SoundPlayer.play(.send)
            onSend()
            return
        }
        // A service named in the message that is not connected: ask first, send after.
        if let pending = MentionDraft.pendingService(in: MentionDraft.reconcile(draftMentions, in: draft)) {
            mention.connectPrompt = pending
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
        SoundPlayer.play(.send)
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
            router.showInWorkbench(.changes, agentID: agent.id)
        case .terminal:
            draft = ""
            showAgentTerminal(agent: agent, server: server)
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

    /// `/terminal`: the agent's terminal in the workbench panel, as the header's terminal button does.
    private func showAgentTerminal(agent: Agent, server: ServerModel) {
        #if os(macOS)
        WorkbenchTerminals.showAgentTerminal(server: server, agent: agent, app: app, router: router)
        #endif
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

    // MARK: Mentions: picking, chips, connecting

    /// Enter, Tab or a click on a row: `@Label ` takes the place of the typed `@word`, and the chip appears.
    private func pickMention(_ entry: MentionEntry) {
        guard let match = mentionMatch else { return }
        let result = MentionDraft.insert(entry, replacing: match, in: draft, list: draftMentions)
        draft = result.draft
        if router.draftMentions[agentID] != result.list { router.draftMentions[agentID] = result.list }
        if mention.index != 0 { mention.index = 0 }
        focused = true
    }

    /// The cross of a chip: its `@Label` goes from the text too.
    private func removeMention(_ item: DraftMention) {
        let token = item.mention.token
        if let range = draft.range(of: token + " ") ?? draft.range(of: token) {
            draft.removeSubrange(range)
        }
        let rest = draftMentions.filter { $0 != item }
        if router.draftMentions[agentID] != rest { router.draftMentions[agentID] = rest }
        focused = true
    }

    /// Text the person deleted takes its chip with it.
    private func reconcileMentions() {
        let current = draftMentions
        guard !current.isEmpty else { return }
        let kept = MentionDraft.reconcile(current, in: draft)
        if kept != current { router.draftMentions[agentID] = kept }
    }

    /// Backspace with the caret at the end of the text, right after a chip: the whole chip goes.
    private func handleBackspace(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty, !draftMentions.isEmpty, FieldCaret.isAtEnd,
            let result = MentionDraft.removeTrailingChip(draft: draft, list: draftMentions)
        else { return .ignored }
        draft = result.draft
        router.draftMentions[agentID] = result.list
        return .handled
    }

    /// "Connect Linear?" above the field, for a service the message names that is not connected.
    private func connectBar(_ item: DraftMention) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Mention.connectPrompt(name: item.mention.label))
                    .font(BanditoFont.text(size: 12.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Text(L10n.Mention.connectHint)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2)
                // An agent with its own list of services gets this one added: said before it happens.
                if agent?.integrations != nil {
                    Text(L10n.Mention.connectAccess(service: item.mention.label, agent: agentName))
                        .font(BanditoFont.text(size: 12, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(L10n.Common.cancel) { mention.connectPrompt = nil }
                .banditoButton(.quiet())
            Button(L10n.Mention.connectAndSend) { connectService(item) }
                .banditoButton(.signal())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.signal.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.Bandito.signal.opacity(0.3), lineWidth: 1))
    }

    /// The same connect as the Marketplace: a service that signs in in the browser starts the sign-in, the others open
    /// the sheet of keys. The message goes when the service is connected.
    private func connectService(_ item: DraftMention) {
        guard let server, let templateID = item.pendingTemplate,
            let snapshot = MentionServices.shared.snapshot(for: server),
            let template = snapshot.catalog.first(where: { $0.id == templateID })
        else { return }
        let known = Set(snapshot.integrations.map(\.id))
        guard template.usesOAuth, let url = template.url else {
            mention.connecting = MentionMenuModel.Connecting(
                agentID: agentID, name: template.name, template: templateID, known: known)
            mention.editing = template
            return
        }
        guard server.supports("integrations_oauth") else {
            mention.notice = UserFacingMessage(text: L10n.Integrations.Oauth.needsUpdate(name: template.name))
            return
        }
        let draft = NewIntegration(name: template.id, kind: .http, url: url)
        Task {
            await app.oauth.begin(server: server, target: .draft(draft), name: template.name)
            if case .waiting = app.oauth.phase {
                mention.connecting = MentionMenuModel.Connecting(
                    agentID: agentID, name: template.name, template: templateID, known: known)
            }
        }
    }

    /// The browser sign-in ended: well, and the message goes; otherwise the prompt stays for another try.
    private func handleSignIn(_ phase: OAuthSignIn.Phase) {
        guard mention.connecting != nil, mention.editing == nil else { return }
        if let id = MentionConnectRules.finishedIntegration(
            connecting: mention.connecting, agentID: mention.agentID, phase: phase)
        {
            finishConnect(integrationID: id)
            return
        }
        switch phase {
        case .idle, .failed: mention.connecting = nil
        default: break
        }
    }

    /// The sheet of keys was closed. If it saved a service (an integration that was not there before), the message
    /// goes; the sheet writes the keys after it saves, so this waits for the close.
    private func keyedServiceClosed() async {
        guard let server, let connecting = mention.connecting, connecting.agentID == mention.agentID else {
            mention.connecting = nil
            return
        }
        await MentionServices.shared.ensure(server, force: true)
        let added = MentionServices.shared.snapshot(for: server)?.integrations.first { !connecting.known.contains($0.id) }
        guard let added else {
            mention.connecting = nil
            return
        }
        finishConnect(integrationID: added.id)
    }

    /// The service is connected: its mention gets the integration, an agent with its own list of services may use it,
    /// and the message goes.
    private func finishConnect(integrationID: String) {
        guard let connecting = mention.connecting, connecting.agentID == mention.agentID, let server, let agent else {
            mention.connecting = nil
            return
        }
        mention.connecting = nil
        let list = MentionDraft.connected(draftMentions, template: connecting.template, integrationID: integrationID)
        if router.draftMentions[agentID] != list { router.draftMentions[agentID] = list }
        mention.connectPrompt = nil
        Task {
            await MentionServices.shared.ensure(server, force: true)
            // The person went to another agent while this ran: nothing is changed or sent.
            guard mention.agentID == connecting.agentID else { return }
            mention.refreshServices(server: server, agent: agent)
            if let ids = agent.integrations, !ids.contains(integrationID) {
                do {
                    try await server.updateAgent(agent.id, patch: AgentPatch(integrations: .set(ids + [integrationID])))
                } catch {
                    mention.notice = UserFacingError.message(for: error)
                    return
                }
            }
            guard mention.agentID == connecting.agentID else { return }
            submit()
        }
    }

    // MARK: Attachments

    /// The "+" menu: files, a screenshot of a region, or the picture on the clipboard.
    private var attachMenu: some View {
        Menu {
            Button(L10n.Composer.Attach.file) { attachFiles() }
            Button(L10n.Composer.Attach.screenshot) { takeScreenshot() }
            Button(L10n.Composer.Attach.clipboard) { attachClipboard() }
                .disabled(!PictureSource.clipboardHoldsOnlyPicture)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 30, height: 30)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .banditoButton(.icon(size: 30, label: L10n.Composer.Attach.label))
        .padding(.bottom, 2)
    }

    /// The files of the draft, in a row above the field: pictures as miniatures, other files as chips.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files) { file in
                    if file.isImage {
                        pictureTile(file)
                    } else {
                        fileChip(file)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }

    /// A picture of 56 pt. A failed one is marked red; an uploading one shows a spinner.
    private func pictureTile(_ file: DraftFile) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                openPicture(file)
            } label: {
                Group {
                    if let preview = file.preview {
                        Image(nsImage: preview).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                }
                .frame(width: 56, height: 56)
                .background(Color.Bandito.surface3)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    stateOverlay(file)
                }
            }
            .banditoButton(.row(cornerRadius: 10))
            .help(file.failureText ?? file.name)
            removeButton(file)
        }
    }

    /// Opens the viewer on a picture of the draft, with the other pictures of the draft to step through. A picture that
    /// has no source to read (a failed one) does nothing.
    private func openPicture(_ file: DraftFile) {
        let pictures = files.compactMap { draft -> (id: UUID, name: String, source: ImageViewerSource)? in
            guard draft.isImage, let source = draft.original else { return nil }
            return (draft.id, draft.name, source)
        }
        guard pictures.contains(where: { $0.id == file.id }) else { return }
        let items = pictures.map { ImageViewerItem(name: $0.name, source: $0.source, openInFiles: nil) }
        let index = pictures.firstIndex { $0.id == file.id } ?? 0
        router.imageViewer = ImageViewerRequest(items: items, index: index, returnFocusAgentID: agent?.id)
    }

    /// A file that is not a picture: its icon, name and size, or what is wrong with it.
    private func fileChip(_ file: DraftFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
            Text(file.name)
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let detail = file.detailText {
                Text(detail)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(file.failureText == nil ? Color.Bandito.text3 : Color.Bandito.danger)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            removeButton(file)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(Color.Bandito.surface3, in: Capsule())
        .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 0.5))
    }

    /// The spinner while a picture uploads, and a red wash when it failed.
    @ViewBuilder
    private func stateOverlay(_ file: DraftFile) -> some View {
        if file.state == .uploading {
            ZStack {
                Color.black.opacity(0.35)
                ProgressView().controlSize(.small)
            }
        } else if file.failureText != nil {
            ZStack {
                Color.Bandito.danger.opacity(0.35)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.white)
            }
        }
    }

    private func removeButton(_ file: DraftFile) -> some View {
        Button {
            AttachmentTrays.shared.remove(file.id, agentID: agent?.id ?? "")
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
        }
        .banditoButton(.icon(size: 18, label: L10n.Composer.Attach.remove))
    }

    private func attachFiles() {
        guard canAttach, let agent, let server else { return }
        let urls = FilePanels.attachmentURLs()
        guard !urls.isEmpty else { return }
        AttachmentTrays.shared.add(urls: urls, agentID: agent.id, server: server)
        focused = true
    }

    private func attachClipboard() {
        guard canAttach, let agent, let server, let data = PictureSource.clipboardPNG() else { return }
        AttachmentTrays.shared.addPicture(data, name: Self.pictureName("Clipboard"), agentID: agent.id, server: server)
        focused = true
    }

    private func takeScreenshot() {
        guard canAttach, let agent, let server else { return }
        Task {
            guard let data = await PictureSource.screenshot() else { return }
            AttachmentTrays.shared.addPicture(data, name: Self.pictureName("Screenshot"), agentID: agent.id, server: server)
        }
    }

    /// A name for a picture that has none: the source and the time, without characters a file name cannot hold.
    static func pictureName(_ source: String) -> String {
        "\(source)-\(Int(Date().timeIntervalSince1970 * 1000)).png"
    }
}

/// Where the caret is in the field being edited. The composer's `TextField` offers no caret, so the field editor is
/// asked.
enum FieldCaret {
    /// No selection, and the caret after the last character. `true` where there is no field editor to ask.
    static var isAtEnd: Bool {
        #if os(macOS)
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return true }
        let range = editor.selectedRange()
        return range.length == 0 && range.location == (editor.string as NSString).length
        #else
        return true
        #endif
    }
}
