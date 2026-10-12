#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// What the bar of actions under a native message shows: one bar for the message under the pointer, and a faint one
/// under the agent's last message (as `MessageContainer` does for its rows). One SwiftUI view for the whole list, moved
/// from message to message, instead of one per row.
@MainActor
@Observable
final class NativeActionsModel {
    var spec: NativeMessageSpec?
    var context: ThreadListContext?
    /// Drawn in full (hover or an open popover), or faint (the agent's last message).
    var full = true
    /// The pointer is on the bar itself: it stays.
    var hovering = false
    var reactOpen = false
    var copied = false
    /// Opens the panel to select the message's text (the list knows the message's view).
    @ObservationIgnored var onSelectText: () -> Void = {}
}

/// The bar: the agent's copy, react, reply, more and the time; the person's time, copy, reply, react.
struct NativeActionsBar: View {
    @Bindable var model: NativeActionsModel
    @State private var copyReset: Task<Void, Never>?

    var body: some View {
        if let spec = model.spec {
            let actions = NativeMessageActions(spec: spec, context: model.context)
            HStack(spacing: 2) {
                if spec.fromUser {
                    if let sentAt = spec.sentAt, model.full { MessageTimeStamp(date: sentAt).equatable() }
                    copyButton(actions)
                    if actions.canReply { button("arrowshape.turn.up.left", L10n.Thread.reply, actions.reply) }
                    if actions.canReact { reactButton(actions) }
                } else {
                    copyButton(actions)
                    if actions.canReact { reactButton(actions) }
                    if actions.canReply { button("arrowshape.turn.up.left", L10n.Thread.reply, actions.reply) }
                    moreMenu(actions)
                    if let sentAt = spec.sentAt, model.full { MessageTimeStamp(date: sentAt).equatable() }
                }
            }
            .frame(height: MessageActionsPlacement.rowHeight)
            .opacity(model.full ? 1 : 0.5)
            .onHover { inside in if model.hovering != inside { model.hovering = inside } }
            .fixedSize()
        }
    }

    private func button(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(MessageActionStyle(label: label))
        .help(label)
    }

    private func copyButton(_ actions: NativeMessageActions) -> some View {
        button(
            model.copied ? "checkmark" : "doc.on.doc", model.copied ? L10n.Message.copied : L10n.Thread.copy
        ) {
            actions.copyRaw()
            model.copied = true
            copyReset?.cancel()
            copyReset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                if !Task.isCancelled { model.copied = false }
            }
        }
    }

    private func reactButton(_ actions: NativeMessageActions) -> some View {
        button(actions.mine == nil ? "face.smiling" : "face.smiling.inverse", L10n.Message.react) {
            model.reactOpen.toggle()
        }
        .popover(isPresented: $model.reactOpen, arrowEdge: .bottom) {
            ReactionPicker(current: actions.mine) { emoji in
                model.reactOpen = false
                actions.react(emoji == actions.mine ? nil : emoji)
            }
        }
    }

    private func moreMenu(_ actions: NativeMessageActions) -> some View {
        Menu {
            Button(L10n.Message.copyAsText, action: actions.copyPlain)
            Button(L10n.Message.selectText) { model.onSelectText() }
            Button(actions.reading ? L10n.Speech.stop : L10n.Speech.read, action: actions.toggleReading)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(MessageActionStyle(label: L10n.Message.more))
        .help(L10n.Message.more)
        .fixedSize()
    }
}

/// The hosting view of a bar, sized to the bar.
final class NativeActionsHost: NSHostingView<NativeActionsBar> {
    let model: NativeActionsModel

    init(full: Bool) {
        let model = NativeActionsModel()
        model.full = full
        self.model = model
        super.init(rootView: NativeActionsBar(model: model))
        sizingOptions = [.intrinsicContentSize]
        safeAreaRegions = []
        isHidden = true
    }

    @available(*, unavailable)
    required init(rootView: NativeActionsBar) { fatalError("not used") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The bar's size for the message and the look it was last measured for: placing it again at each step of a
    /// scroll or a layout measured the SwiftUI bar every time.
    private var sized: (spec: NativeMessageSpec, full: Bool, size: CGSize)?

    /// Puts the bar under `bubble` (in the table's coordinates): on its left edge for the agent, its right for the person.
    func place(under bubble: CGRect, fromUser: Bool) {
        let size: CGSize
        if let sized, let spec = model.spec, sized.full == model.full, sized.spec == spec {
            size = sized.size
        } else {
            layoutSubtreeIfNeeded()
            size = fittingSize
            sized = model.spec.map { ($0, model.full, size) }
        }
        let x = fromUser ? bubble.maxX - size.width : bubble.minX
        let frame = CGRect(x: x, y: bubble.maxY, width: size.width, height: MessageActionsPlacement.rowHeight)
        if self.frame != frame { self.frame = frame }
    }
}
#endif
