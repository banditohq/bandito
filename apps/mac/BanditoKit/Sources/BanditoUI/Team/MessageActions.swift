import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// What the rows of a thread need beyond the items: reactions, replies, files, forms, and the ways to act on them.
/// `ThreadView` builds one from the thread and the server's features; a thread shown on its own (a snapshot) gets the
/// empty one.
struct ThreadChat {
    /// The daemon has `reactions`: chips under messages, the reaction button and the double click.
    var reactionsOn = false
    /// The daemon has `attachments`: replies and the files a message carries.
    var repliesOn = false
    /// The daemon has `forms`.
    var formsOn = false
    var agentName = ""
    /// The agent's colour: the bar of a quote, the flash of a message that was jumped to.
    var accent: Color = Color.Bandito.signal
    var reactions: [Int64: MessageReactions] = [:]
    /// The message each reply answers, by the reply's `seq`.
    var replies: [Int64: Int64] = [:]
    var attachments: [Int64: [MessageAttachment]] = [:]
    /// The `@` mentions each message carries, by `seq`: chips under the bubble.
    var mentions: [Int64: [Mention]] = [:]
    /// Messages shown while they wait for their turn, by `seq`: they carry a quiet "Queued" line.
    var waiting: Set<Int64> = []
    /// Messages the daemon gave up on (no turn will take them), by `seq`: a quiet "Not delivered" line, and Send again.
    var undelivered: Set<Int64> = []
    /// Sends the text of an undelivered message again.
    var onResend: (Int64) -> Void = { _ in }
    /// The id of the row that flashes after a jump to it.
    var highlightedID: String?
    /// The row id of the agent's last message. Its action row stays faintly visible (see `MessageActionsPlacement`).
    var lastAgentID: String?
    /// A loaded message by `seq`, for a quote. Nil when it is not on screen's history.
    var original: (Int64) -> ReplyTarget? = { _ in nil }
    var onReply: (ReplyTarget) -> Void = { _ in }
    /// Puts the emoji on the message, or takes the person's reaction off with nil.
    var onReact: (Int64, String?) -> Void = { _, _ in }
    var onJump: (Int64) -> Void = { _ in }
    var onAnswerForm: (FormRow, FormAction, [String: JSONValue]?, String?) async throws -> Void = { _, _, _, _ in }
}

/// A message with what a person does to it: a bar of actions on hover (reply, react, copy, more), the same actions
/// in the context menu, a double click that likes an agent's message, and the reactions as chips below.
struct MessageContainer<Bubble: View>: View {
    /// The row id of the message, for the flash after a jump.
    var itemID: String
    /// The `seq` of the message, or nil when it cannot take reactions or replies (a message finalized from a stream
    /// has no event of its own).
    var seq: Int64?
    var text: String
    var fromUser: Bool
    var chat: ThreadChat
    /// The files the message carries, drawn under the bubble (see `MessageFiles`).
    var files: [AgentAttachment] = []
    var agentID = ""
    var server: ServerModel?
    @ViewBuilder var bubble: () -> Bubble

    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    @State private var reactOpen = false
    @State private var selecting = false
    /// The mouse is down and moving over the bubble: a text selection is under way, so the row stays away.
    @State private var dragging = false
    @State private var copied = false
    /// Keyboard focus in the row: on the bubble or on one of the action buttons. The action row shows while it is there.
    private enum Part { case bubble, actions }
    @FocusState private var focus: Part?
    @State private var copyReset: Task<Void, Never>?

    private var canReact: Bool { chat.reactionsOn && seq != nil }
    private var canReply: Bool { chat.repliesOn && seq != nil }
    private var mine: String? { seq.flatMap { chat.reactions[$0]?.mine } }
    private var chips: [ReactionChip] { seq.flatMap { chat.reactions[$0]?.chips } ?? [] }
    private var flashing: Bool { chat.highlightedID == itemID }
    /// This message is the one being read aloud: its menu says "Stop reading".
    private var reading: Bool { SpeechOutput.shared.speakingKey == itemID }
    private var readTitle: String { reading ? L10n.Speech.stop : L10n.Speech.read }
    private var rowOpacity: Double {
        MessageActionsPlacement.opacity(
            hovering: hovering, open: reactOpen || selecting || focus != nil, selectingText: dragging, isUser: fromUser,
            isLastAgent: itemID == chat.lastAgentID)
    }

    var body: some View {
        HStack(spacing: 0) {
            if fromUser { Spacer(minLength: 120) }
            VStack(alignment: fromUser ? .trailing : .leading, spacing: 5) {
                bubble()
                    // The double click is caught behind the bubble: on its padding and background, not on the text,
                    // where a double click selects a word and a link opens.
                    .background {
                        if !fromUser, canReact {
                            Color.clear.contentShape(Rectangle()).onTapGesture(count: 2, perform: toggleLike)
                        }
                    }
                    .onHover(perform: setHover)
                    .focusable()
                    .focused($focus, equals: .bubble)
                    .accessibilityActions {
                        Button(L10n.Thread.copy, action: copyRaw)
                        if canReply { Button(L10n.Thread.reply, action: reply) }
                        if canReact, let seq {
                            ForEach(ReactionRules.common, id: \.self) { emoji in
                                Button("\(L10n.Message.react) \(emoji)") {
                                    chat.onReact(seq, emoji == mine ? nil : emoji)
                                }
                            }
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { _ in if !dragging { dragging = true } }
                            .onEnded { _ in if dragging { dragging = false } })
                    .contextMenu { contextMenuItems }
                    .popover(isPresented: $selecting, arrowEdge: .bottom) {
                        SelectableTextPanel(text: text)
                    }
                if !chips.isEmpty, let seq {
                    ReactionChipsRow(chips: chips, agentName: chat.agentName) { chip in
                        chat.onReact(seq, chip.byUser ? nil : chip.emoji)
                    }
                }
                if !files.isEmpty, let server {
                    MessageFiles(files: files, agentID: agentID, server: server)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(chat.accent.opacity(flashing ? 0.2 : 0))
            )
            .padding(-6)
            .banditoAnimation(.easeOut(duration: 0.3), value: flashing)
            // The row hangs under the bubble, from its edge, and is drawn over the reserved space below it.
            // It exists only while it is drawn: a thread of hundreds of messages would otherwise hold hundreds of
            // hidden buttons, menus and hover areas, and update them all on every scroll.
            .overlay(alignment: Alignment(horizontal: MessageActionsPlacement.edge(isUser: fromUser), vertical: .bottom)) {
                if rowOpacity > 0 {
                    actionRow.offset(y: MessageActionsPlacement.rowHeight)
                        .transition(.opacity)
                }
            }
            .banditoAnimation(.easeOut(duration: 0.12), value: rowOpacity > 0)
            if !fromUser { Spacer(minLength: 120) }
        }
        .padding(.bottom, MessageActionsPlacement.reservedBelow)
        .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
        // After a reaction is picked the row goes away; it comes back when the pointer re-enters.
        .onChange(of: reactOpen) { _, open in if !open && hovering { setHover(false) } }
        .onDisappear {
            hideTask?.cancel()
            copyReset?.cancel()
        }
    }

    // MARK: Hover

    /// The row stays a moment (250 ms) after the pointer leaves the bubble, so that it can be reached across the gap.
    private func setHover(_ on: Bool) {
        hideTask?.cancel()
        hideTask = nil
        if on {
            // Content moving under a still pointer reports hover again and again: while the thread scrolls, rows do
            // not light up (each would be built for a fraction of a second). They do at the next move of the pointer.
            if ThreadScrollActivity.isScrolling() { return }
            // A hover event repeats while the content moves under a still pointer: write only a real change.
            if !hovering { hovering = true }
        } else if hovering {
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled, hovering { hovering = false }
            }
        }
    }

    // MARK: The row

    /// The icons under the bubble. The agent's: copy, react, reply, more. The person's: copy, reply, react.
    private var actionRow: some View {
        HStack(spacing: 2) {
            if fromUser {
                copyButton
                if canReply { replyButton }
                if canReact { reactButton }
            } else {
                copyButton
                if canReact { reactButton }
                if canReply { replyButton }
                moreMenu
            }
        }
        .frame(height: MessageActionsPlacement.rowHeight)
        .opacity(rowOpacity)
        .allowsHitTesting(rowOpacity > 0)
        .onHover(perform: setHover)
        .banditoAnimation(.easeOut(duration: 0.12), value: rowOpacity)
    }

    private var copyButton: some View {
        actionButton(
            icon: copied ? "checkmark" : "doc.on.doc", label: copied ? L10n.Message.copied : L10n.Thread.copy,
            action: copyRaw)
    }

    private var replyButton: some View {
        actionButton(icon: "arrowshape.turn.up.left", label: L10n.Thread.reply, action: reply)
    }

    private var reactButton: some View {
        actionButton(icon: mine == nil ? "face.smiling" : "face.smiling.inverse", label: L10n.Message.react) {
            reactOpen.toggle()
        }
        .popover(isPresented: $reactOpen, arrowEdge: .bottom) {
            ReactionPicker(current: mine) { emoji in
                reactOpen = false
                guard let seq else { return }
                chat.onReact(seq, emoji == mine ? nil : emoji)
            }
        }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(MessageActionStyle(label: label))
        .focused($focus, equals: .actions)
        .help(label)
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.Message.copyAsText, action: copyPlain)
            Button(L10n.Message.selectText) { selecting = true }
            if !fromUser {
                Button(readTitle, action: toggleReading)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(MessageActionStyle(label: L10n.Message.more))
        .focused($focus, equals: .actions)
        .help(L10n.Message.more)
        .fixedSize()
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if canReply {
            Button(L10n.Thread.reply, action: reply)
        }
        if canReact, let seq {
            Menu(L10n.Message.react) {
                ForEach(ReactionRules.common, id: \.self) { emoji in
                    Button(emoji) { chat.onReact(seq, emoji == mine ? nil : emoji) }
                }
                Divider()
                Button(L10n.Message.reactMore) {
                    hovering = true
                    reactOpen = true
                }
            }
        }
        if fromUser, let seq, chat.undelivered.contains(seq) {
            Button(L10n.Message.resend) { chat.onResend(seq) }
        }
        if canReply || canReact || (seq.map { chat.undelivered.contains($0) } ?? false) { Divider() }
        Button(L10n.Thread.copy, action: copyRaw)
        Button(L10n.Message.copyAsText, action: copyPlain)
        Button(L10n.Message.selectText) { selecting = true }
        if !fromUser {
            Button(readTitle, action: toggleReading)
        }
    }

    // MARK: Actions

    private func reply() {
        guard let seq else { return }
        chat.onReply(ReplyTarget(seq: seq, fromUser: fromUser, text: text))
    }

    /// The message as it was written, Markdown and all.
    private func copyRaw() {
        SystemActions.copy(text)
        copied = true
        copyReset?.cancel()
        copyReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { copied = false }
        }
    }

    private func copyPlain() {
        SystemActions.copy(MessageBlocks.plainText(text))
    }

    /// Reads the message aloud, or stops it. Markdown is read as plain sentences; a code block is not read.
    private func toggleReading() {
        if reading {
            SpeechOutput.shared.stop()
            return
        }
        let spoken = SpeechText.plain(text, codeSkipped: L10n.Speech.codeSkipped)
        let voice = SpeechLanguage.voiceTag(for: spoken, appLanguage: SpeechLanguage.appLanguage)
        SpeechOutput.shared.speak(spoken, key: itemID, voiceTag: voice)
    }

    /// A double click on the agent's message likes it, or takes the like off.
    private func toggleLike() {
        guard canReact, let seq else { return }
        chat.onReact(seq, mine == ReactionRules.common[0] ? nil : ReactionRules.common[0])
    }
}

/// An icon of the action row: 28 pt, no plate. On hover a circle of `text` at 7% lights up, and a press shrinks the icon
/// to 0.92. The icon is `text3`, and `text` on hover.
struct MessageActionStyle: ButtonStyle {
    var label: String

    func makeBody(configuration: Configuration) -> some View {
        InteractiveBody(isPressed: configuration.isPressed) { hovered in
            configuration.label
                .foregroundStyle(hovered ? Color.Bandito.text : Color.Bandito.text3)
                .frame(width: MessageActionsPlacement.rowHeight, height: MessageActionsPlacement.rowHeight)
                .background(Circle().fill(Color.Bandito.text.opacity(hovered ? 0.07 : 0)))
                .contentShape(Circle())
                // InteractiveBody already presses to 0.97; this factor brings the whole press to 0.92.
                .scaleEffect(configuration.isPressed ? 0.92 / 0.97 : 1)
                .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: configuration.isPressed)
                .brandFocusRing(shape: Circle())
                .accessibilityLabel(label)
        }
    }
}

/// One of the quick reactions in the popover: 22 pt, growing to 1.2 under the pointer with a spring.
private struct QuickReaction: View {
    var emoji: String
    var isCurrent: Bool
    var onPick: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onPick) {
            Text(emoji)
                .font(BanditoFont.text(size: 22, weight: 400))
                .scaleEffect(hovered ? 1.2 : 1)
                .banditoAnimation(.spring(response: 0.3, dampingFraction: 0.5), value: hovered)
                .frame(width: 34, height: 34)
                .background(
                    isCurrent ? Color.Bandito.signal.opacity(0.18) : Color.clear, in: Circle())
                .onHover { hovered = $0 }
        }
        .banditoButton(.row(cornerRadius: 17, hoverOpacity: 0.07))
        .accessibilityLabel(emoji)
    }
}

// MARK: - Reactions

/// The reactions under a message. Your own is lit; a click takes it off. A click on one the agent put there adds yours.
struct ReactionChipsRow: View {
    var chips: [ReactionChip]
    var agentName: String
    var onTap: (ReactionChip) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Button {
                    onTap(chip)
                } label: {
                    HStack(spacing: 4) {
                        Text(chip.emoji)
                            .font(BanditoFont.text(size: 14, weight: 400))
                        if chip.byUser && chip.byAgent {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.Bandito.text3)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(chip.byUser ? Color.Bandito.signal.opacity(0.16) : Color.Bandito.text.opacity(0.05))
                    )
                    .overlay(
                        Capsule().stroke(
                            chip.byUser ? Color.Bandito.signal.opacity(0.5) : Color.Bandito.line, lineWidth: 1))
                    .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.row(cornerRadius: 12))
                .help(chip.byUser ? L10n.Message.reactionMine : L10n.Message.reactionSame)
                .accessibilityLabel(chip.byUser ? "\(chip.emoji) \(L10n.Message.reactionMine)" : "\(chip.emoji) \(L10n.Message.reactionOf(name: agentName))")
                .accessibilityAddTraits(chip.byUser ? .isSelected : [])
            }
        }
    }
}

/// The popover of the react button: the six usual emoji, and "More…", which opens the system emoji picker.
struct ReactionPicker: View {
    var current: String?
    var onPick: (String) -> Void

    @State private var more = false
    @State private var typed = ""
    @FocusState private var typedFocused: Bool

    /// A few more, for when the system panel does not come up.
    private static let extra = [
        "🙏", "🎉", "😮", "😢", "🤔", "👏", "💯", "🚀",
        "👎", "😅", "🙌", "💡", "🐛", "⚠️", "❌", "🤝",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The quick row: a capsule of the usual emoji, then "+" for the system panel.
            HStack(spacing: 2) {
                ForEach(ReactionRules.common, id: \.self) { emoji in
                    QuickReaction(emoji: emoji, isCurrent: emoji == current) { onPick(emoji) }
                }
                plusButton
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.Bandito.surface2))
            .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            if more {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Message.reactPickerHint)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("", text: $typed)
                        .banditoField()
                        .font(BanditoFont.text(size: 18, weight: 400))
                        .focused($typedFocused)
                        .accessibilityLabel(L10n.Message.reactMore)
                        .onChange(of: typed) { _, text in
                            if let emoji = ReactionRules.firstEmoji(in: text) { onPick(emoji) }
                        }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 2), count: 8), spacing: 2) {
                        ForEach(Self.extra, id: \.self) { emojiButton($0, size: 18) }
                    }
                }
            }
        }
        .padding(12)
        .fixedSize()
    }

    /// "+": opens the system's emoji panel and the field that takes what is typed into it.
    private var plusButton: some View {
        Button {
            more = true
            typedFocused = true
            Self.openSystemPicker()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(MessageActionStyle(label: L10n.Message.reactMore))
        .help(L10n.Message.reactMore)
    }

    private func emojiButton(_ emoji: String, size: CGFloat) -> some View {
        Button {
            onPick(emoji)
        } label: {
            Text(emoji)
                .font(BanditoFont.text(size: size, weight: 400))
                .frame(width: 34, height: 34)
                .background(
                    emoji == current ? Color.Bandito.signal.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 8))
        .accessibilityLabel(emoji)
    }

    /// The system's character panel. It types into the focused field, which `onChange` reads.
    private static func openSystemPicker() {
        #if os(macOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.orderFrontCharacterPalette(nil)
        }
        #endif
    }
}

// MARK: - Files and selecting

/// The whole text of a message with everything selected, so that a part of it can be picked and copied.
struct SelectableTextPanel: View {
    var text: String

    var body: some View {
        #if os(macOS)
        SelectableTextView(text: text)
            .frame(width: 440, height: min(max(CGFloat(text.count) / 2.2, 90), 300))
        #else
        ScrollView {
            Text(text).textSelection(.enabled).padding(12)
        }
        .frame(width: 440, height: 240)
        #endif
    }
}

#if os(macOS)
private struct SelectableTextView: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = BanditoFont.appKitText(size: 13.5)
            view.textColor = NSColor(Color.Bandito.text)
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.string = text
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                view.selectAll(nil)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
    }
}
#endif
