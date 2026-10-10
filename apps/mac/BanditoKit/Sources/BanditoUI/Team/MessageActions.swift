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
    /// The id of the row that flashes after a jump to it.
    var highlightedID: String?
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
    @ViewBuilder var bubble: () -> Bubble

    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    @State private var reactOpen = false
    @State private var selecting = false
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    private var canReact: Bool { chat.reactionsOn && seq != nil }
    private var canReply: Bool { chat.repliesOn && seq != nil }
    private var mine: String? { seq.flatMap { chat.reactions[$0]?.mine } }
    private var chips: [ReactionChip] { seq.flatMap { chat.reactions[$0]?.chips } ?? [] }
    private var files: [MessageAttachment] { seq.flatMap { chat.attachments[$0] } ?? [] }
    private var flashing: Bool { chat.highlightedID == itemID }

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
                    .overlay(alignment: .topTrailing) { actionBar.offset(x: -6, y: -14) }
                    .onHover(perform: setHover)
                    .contextMenu { contextMenuItems }
                    .popover(isPresented: $selecting, arrowEdge: .bottom) {
                        SelectableTextPanel(text: text)
                    }
                if !chips.isEmpty, let seq {
                    ReactionChipsRow(chips: chips, agentName: chat.agentName) { chip in
                        chat.onReact(seq, chip.byUser ? nil : chip.emoji)
                    }
                }
                if !files.isEmpty {
                    AttachmentChips(files: files)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(chat.accent.opacity(flashing ? 0.2 : 0))
            )
            .padding(-6)
            .banditoAnimation(.easeOut(duration: 0.3), value: flashing)
            if !fromUser { Spacer(minLength: 120) }
        }
        .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
        // After a reaction is picked the bar goes away; it comes back when the pointer re-enters.
        .onChange(of: reactOpen) { _, open in if !open { setHover(false) } }
        .onDisappear {
            hideTask?.cancel()
            copyReset?.cancel()
        }
    }

    // MARK: Hover

    private var barVisible: Bool { hovering || reactOpen || selecting }

    /// The bar stays a moment after the pointer leaves the bubble, so that it can be reached across the gap.
    private func setHover(_ on: Bool) {
        hideTask?.cancel()
        if on {
            hovering = true
        } else {
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                if !Task.isCancelled { hovering = false }
            }
        }
    }

    // MARK: The bar

    private var actionBar: some View {
        HStack(spacing: 2) {
            if canReply {
                barButton(icon: "arrowshape.turn.up.left", label: L10n.Thread.reply, action: reply)
            }
            if canReact {
                barButton(icon: mine == nil ? "face.smiling" : "face.smiling.inverse", label: L10n.Message.react) {
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
            barButton(
                icon: copied ? "checkmark" : "doc.on.doc", label: copied ? L10n.Message.copied : L10n.Thread.copy,
                action: copyRaw)
            moreMenu
        }
        .padding(3)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        // Hidden, not removed: an open menu belongs to the bar, and a bar that left the tree would close it.
        .opacity(barVisible ? 1 : 0)
        .allowsHitTesting(barVisible)
        .onHover(perform: setHover)
        .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: barVisible)
    }

    private func barButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .banditoButton(.icon(size: 26, label: label))
        .help(label)
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.Message.copyAsText, action: copyPlain)
            Button(L10n.Message.selectText) { selecting = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .banditoButton(.icon(size: 26, label: L10n.Message.more))
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
        if canReply || canReact { Divider() }
        Button(L10n.Thread.copy, action: copyRaw)
        Button(L10n.Message.copyAsText, action: copyPlain)
        Button(L10n.Message.selectText) { selecting = true }
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
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }

    private func copyPlain() {
        SystemActions.copy(MessageBlocks.plainText(text))
    }

    /// A double click on the agent's message likes it, or takes the like off.
    private func toggleLike() {
        guard canReact, let seq else { return }
        chat.onReact(seq, mine == ReactionRules.common[0] ? nil : ReactionRules.common[0])
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
                            .font(.system(size: 14))
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
            HStack(spacing: 2) {
                ForEach(ReactionRules.common, id: \.self) { emoji in
                    emojiButton(emoji, size: 22)
                }
            }
            if more {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.Message.reactPickerHint)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("", text: $typed)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Bandito.line))
                        .focused($typedFocused)
                        .accessibilityLabel(L10n.Message.reactMore)
                        .onChange(of: typed) { _, text in
                            if let emoji = ReactionRules.firstEmoji(in: text) { onPick(emoji) }
                        }
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 2), count: 8), spacing: 2) {
                        ForEach(Self.extra, id: \.self) { emojiButton($0, size: 18) }
                    }
                }
            } else {
                Button {
                    more = true
                    typedFocused = true
                    Self.openSystemPicker()
                } label: {
                    Text(L10n.Message.reactMore)
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .banditoButton(.link)
            }
        }
        .padding(12)
        .fixedSize()
    }

    private func emojiButton(_ emoji: String, size: CGFloat) -> some View {
        Button {
            onPick(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: size))
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

/// The files a message carries, by name.
struct AttachmentChips: View {
    var files: [MessageAttachment]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                HStack(spacing: 5) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10))
                    Text(file.name)
                        .font(BanditoFont.font(size: 11.5, weight: 500))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(Color.Bandito.text2)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Color.Bandito.text.opacity(0.05)))
                .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
                .help(file.name)
            }
        }
    }
}

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
            view.font = .systemFont(ofSize: 13.5)
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
