import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

/// What the chat's cells ask of the screen.
@MainActor
protocol ChatCellActions: AnyObject {
    func openLink(_ url: URL)
    func copy(_ text: String)
    func toggleFold(_ rowID: String)
    func resend(seq: Int64)
    func retry(queueID: String)
    func discard(queueID: String)
    func openChanges()
    /// Puts the emoji on the message, or takes the person's reaction off with nil.
    func react(seq: Int64, emoji: String?)
    /// The person answers this message: the box shows its quote and the next send carries it.
    func reply(to target: ReplyTarget)
    /// Shows the text of a message in a sheet where a part of it can be selected.
    func selectText(_ text: String)
    func share(_ text: String)
    /// Goes to the message a reply quotes.
    func jump(toSeq seq: Int64)
    /// The menu of a message is about to open (a tap of the Taptic Engine).
    func menuWillOpen()
}

// MARK: - message

/// A message: the bubble, the blocks in it (text, code, rules), the pictures and files above it, the reactions and the
/// small line under it. Views are kept per cell and reused for the next message; the frames come from the measured
/// layout. The parts that belong to the message itself live in `body`, which is what a long press lifts (the bubble
/// alone has no text in it: the text is drawn by sibling views).
final class ChatMessageCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    static let reuse = ChatCellID.message

    weak var actions: ChatCellActions?
    private(set) var rowID = ""
    private var message: ChatMessage?
    private var layout: ChatMessageLayout?

    private let senderView = ChatTextView()
    private let body = UIView()
    private let bubble = ChatBubbleView()
    private let metaView = ChatTextView()
    private var texts: [ChatTextView] = []
    private var codes: [ChatCodeBlockView] = []
    private var plains: [UIView] = []
    private var pictures: [ChatPictureView] = []
    private var chips: [ChatFileChipView] = []
    private var reactionViews: [ChatReactionChipView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        body.frame = contentView.bounds
        body.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(senderView)
        contentView.addSubview(body)
        body.addSubview(bubble)
        contentView.addSubview(metaView)
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        contentView.addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityIdentifier = "chat.message"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(row: ChatRow, message: ChatMessage, layout: ChatMessageLayout, speaker: String, actions: ChatCellActions) {
        self.actions = actions
        rowID = row.id
        self.message = message
        self.layout = layout

        senderView.string = layout.sender?.string
        senderView.isHidden = layout.sender == nil
        if let sender = layout.sender { senderView.frame = sender.frame }

        if let frame = layout.bubble {
            bubble.isHidden = false
            bubble.frame = frame
            bubble.configure(mine: layout.isMine, tail: layout.tail)
        } else {
            bubble.isHidden = true
        }

        var textIndex = 0, codeIndex = 0, plainIndex = 0
        for block in layout.blocks {
            switch block {
            case .text(let item):
                let view = take(&texts, textIndex) { ChatTextView() }
                textIndex += 1
                view.string = item.string
                view.frame = item.frame
            case .code(let item):
                let view = take(&codes, codeIndex) {
                    let view = ChatCodeBlockView()
                    view.onCopy = { [weak self] code in self?.actions?.copy(code) }
                    return view
                }
                codeIndex += 1
                view.frame = item.frame
                view.configure(item)
            case .rule(let rect):
                let view = take(&plains, plainIndex) { UIView() }
                plainIndex += 1
                view.frame = rect
                view.layer.cornerRadius = 0
                view.backgroundColor = UIColor.Bandito.line
            case .bar(let rect):
                let view = take(&plains, plainIndex) { UIView() }
                plainIndex += 1
                view.frame = rect
                view.layer.cornerRadius = 1.5
                view.backgroundColor = UIColor.Bandito.lineStrong
            case .panel(let rect):
                let view = take(&plains, plainIndex) { UIView() }
                plainIndex += 1
                view.frame = rect
                view.layer.cornerRadius = 8
                view.layer.cornerCurve = .continuous
                view.backgroundColor = UIColor.Bandito.text.withAlphaComponent(0.06)
            }
        }
        hide(texts, from: textIndex)
        hide(codes, from: codeIndex)
        hide(plains, from: plainIndex)

        var pictureIndex = 0, chipIndex = 0
        for item in layout.files {
            if item.isPicture {
                let view = take(&pictures, pictureIndex) { ChatPictureView() }
                pictureIndex += 1
                view.frame = item.frame
                view.configure(item.file, image: ChatPictures.image(path: item.file.path))
            } else {
                let view = take(&chips, chipIndex) { ChatFileChipView() }
                chipIndex += 1
                view.frame = item.frame
                view.configure(item.file)
            }
        }
        hide(pictures, from: pictureIndex)
        hide(chips, from: chipIndex)

        for (index, item) in layout.chips.enumerated() {
            let view = take(&reactionViews, index) { ChatReactionChipView() }
            view.frame = item.frame
            view.configure(item.chip)
        }
        hide(reactionViews, from: layout.chips.count)

        metaView.string = layout.meta?.string
        metaView.isHidden = layout.meta == nil
        if let meta = layout.meta { metaView.frame = meta.frame }

        let caption = layout.meta?.string.string
        accessibilityLabel = [speaker + ":", layout.spoken, caption].compactMap { $0 }.joined(separator: " ")
        accessibilityCustomActions = customActions(for: message)
    }

    private func take<V: UIView>(_ pool: inout [V], _ index: Int, make: () -> V) -> V {
        if index < pool.count {
            let view = pool[index]
            view.isHidden = false
            return view
        }
        let view = make()
        pool.append(view)
        body.addSubview(view)
        return view
    }

    private func hide<V: UIView>(_ pool: [V], from index: Int) {
        guard index < pool.count else { return }
        for view in pool[index...] { view.isHidden = true }
    }

    private func customActions(for message: ChatMessage) -> [UIAccessibilityCustomAction] {
        var found: [UIAccessibilityCustomAction] = []
        let items = ChatMessageMenu.items(for: message, link: nil, plain: layout?.plain ?? message.text)
        let mine = ChatMessageMenu.mine(message)
        for item in items {
            switch item {
            case .copy:
                found.append(
                    UIAccessibilityCustomAction(name: L10n.Thread.copy) { [weak self] _ in
                        guard let self, let layout = self.layout else { return false }
                        self.actions?.copy(layout.plain)
                        return true
                    })
            case .reply:
                guard let seq = message.seq else { continue }
                let target = ReplyTarget(seq: seq, fromUser: message.isMine, text: message.text)
                found.append(
                    UIAccessibilityCustomAction(name: L10n.Thread.reply) { [weak self] _ in
                        self?.actions?.reply(to: target)
                        return true
                    })
            case .reactions:
                guard let seq = message.seq, UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning else { continue }
                for emoji in ReactionRules.common {
                    found.append(
                        UIAccessibilityCustomAction(name: "\(L10n.Message.react) \(emoji)") { [weak self] _ in
                            self?.actions?.react(seq: seq, emoji: ChatMessageMenu.pick(emoji, mine: mine))
                            return true
                        })
                }
            case .selectText:
                found.append(
                    UIAccessibilityCustomAction(name: L10n.Message.selectText) { [weak self] _ in
                        guard let self, let layout = self.layout else { return false }
                        self.actions?.selectText(layout.plain)
                        return true
                    })
            case .share:
                found.append(
                    UIAccessibilityCustomAction(name: L10n.Ios.Chat.share) { [weak self] _ in
                        guard let self, let layout = self.layout else { return false }
                        self.actions?.share(layout.plain)
                        return true
                    })
            case .resend(let seq):
                found.append(
                    UIAccessibilityCustomAction(name: L10n.Message.resend) { [weak self] _ in
                        self?.actions?.resend(seq: seq)
                        return true
                    })
            case .retry(let id):
                found.append(
                    UIAccessibilityCustomAction(name: L10n.Ios.Chat.retry) { [weak self] _ in
                        self?.actions?.retry(queueID: id)
                        return true
                    })
            case .discard(let id):
                found.append(
                    UIAccessibilityCustomAction(name: L10n.Ios.Chat.discard) { [weak self] _ in
                        self?.actions?.discard(queueID: id)
                        return true
                    })
            case .copyMarkdown, .openLink, .copyLink:
                continue
            }
        }
        // A chip under the message is a button of its own for those who cannot touch it.
        if let seq = message.seq {
            for chip in message.reactions {
                let name = chip.byUser ? L10n.Message.reactionMine : L10n.Message.reactionSame
                found.append(
                    UIAccessibilityCustomAction(name: "\(chip.emoji) \(name)") { [weak self] _ in
                        self?.actions?.react(seq: seq, emoji: ChatMessageMenu.tap(chip))
                        return true
                    })
            }
        }
        return found
    }

    // MARK: touches

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: contentView)
        if let chip = reactionChip(at: point), let seq = message?.seq {
            actions?.react(seq: seq, emoji: ChatMessageMenu.tap(chip))
            return
        }
        if let quote = layout?.quote, let seq = layout?.quoteSeq, quote.contains(point) {
            actions?.jump(toSeq: seq)
            return
        }
        if let url = link(at: point) {
            actions?.openLink(url)
            return
        }
        guard let message, let meta = layout?.meta, meta.frame.insetBy(dx: -12, dy: -10).contains(point) else { return }
        switch message.caption {
        case .notDelivered(let seq)?: actions?.resend(seq: seq)
        case .notSent(let id, _)?, .uncertain(let id)?: actions?.retry(queueID: id)
        default: break
        }
    }

    /// The reaction chip under a point; the touch area is wider and taller than the 24 pt capsule.
    private func reactionChip(at point: CGPoint) -> ChatReactionChip? {
        guard let layout else { return nil }
        for item in layout.chips where item.frame.insetBy(dx: -4, dy: -10).contains(point) { return item.chip }
        return nil
    }

    private func link(at point: CGPoint) -> URL? {
        for view in texts where !view.isHidden {
            if let url = view.link(at: contentView.convert(point, to: view)) { return url }
        }
        return nil
    }

    // MARK: menu

    /// The part of the row a long press can lift: the bubble and the files above it.
    private var liftedFrames: [CGRect] {
        guard let layout else { return [] }
        var frames: [CGRect] = []
        if let bubble = layout.bubble { frames.append(bubble) }
        frames.append(contentsOf: layout.files.map(\.frame))
        return frames
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let message, let layout else { return nil }
        // Only on the message itself: a press on the empty part of the row opens nothing.
        guard liftedFrames.contains(where: { $0.insetBy(dx: -6, dy: -6).contains(location) }) else { return nil }
        let url = link(at: location)
        let entries = ChatMessageMenu.items(for: message, link: url, plain: layout.plain)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return self.menu(for: entries, message: message, layout: layout)
        }
    }

    private func menu(for entries: [ChatMessageMenu.Item], message: ChatMessage, layout: ChatMessageLayout) -> UIMenu {
        var top: [UIMenuElement] = []
        var middle: [UIMenuElement] = []
        var bottom: [UIMenuElement] = []
        let mine = ChatMessageMenu.mine(message)
        for entry in entries {
            switch entry {
            case .openLink(let url):
                top.append(
                    UIAction(title: L10n.Ios.Chat.openInSafari, image: UIImage(systemName: "safari")) { [weak self] _ in
                        self?.actions?.openLink(url)
                    })
            case .copyLink(let url):
                top.append(
                    UIAction(title: L10n.Ios.Chat.copyLink, image: UIImage(systemName: "link")) { [weak self] _ in
                        self?.actions?.copy(url.absoluteString)
                    })
            case .reactions:
                guard let seq = message.seq else { continue }
                top.append(contentsOf: reactionPalettes(seq: seq, mine: mine))
            case .reply:
                guard let seq = message.seq else { continue }
                let target = ReplyTarget(seq: seq, fromUser: message.isMine, text: message.text)
                middle.append(
                    UIAction(title: L10n.Thread.reply, image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
                        self?.actions?.reply(to: target)
                    })
            case .resend(let seq):
                middle.append(
                    UIAction(title: L10n.Message.resend, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                        self?.actions?.resend(seq: seq)
                    })
            case .retry(let id):
                middle.append(
                    UIAction(title: L10n.Ios.Chat.retry, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                        self?.actions?.retry(queueID: id)
                    })
            case .discard(let id):
                bottom.append(
                    UIAction(title: L10n.Ios.Chat.discard, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                        self?.actions?.discard(queueID: id)
                    })
            case .copy:
                middle.append(
                    UIAction(title: L10n.Thread.copy, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        self?.actions?.copy(layout.plain)
                    })
            case .copyMarkdown:
                let body = message.text
                middle.append(
                    UIAction(title: L10n.Thread.copyMarkdown, image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                        self?.actions?.copy(body)
                    })
            case .selectText:
                middle.append(
                    UIAction(title: L10n.Message.selectText, image: UIImage(systemName: "text.cursor")) { [weak self] _ in
                        self?.actions?.selectText(layout.plain)
                    })
            case .share:
                middle.append(
                    UIAction(title: L10n.Ios.Chat.share, image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                        self?.actions?.share(layout.plain)
                    })
            }
        }
        return UIMenu(children: top + middle + bottom)
    }

    /// The Mac's quick reactions as palettes at the top of the menu (`ChatMessageMenu.paletteRows`: the menu is about six small
    /// buttons wide, and a longer row scrolls sideways, which hides what is at its end). The person's own is lit.
    private func reactionPalettes(seq: Int64, mine: String?) -> [UIMenuElement] {
        ChatMessageMenu.paletteRows().map { row in
            let actions = row.map { emoji in
                UIAction(
                    title: emoji, image: ChatEmojiImages.image(emoji), state: emoji == mine ? .on : .off
                ) { [weak self] _ in
                    self?.actions?.react(seq: seq, emoji: ChatMessageMenu.pick(emoji, mine: mine))
                }
            }
            let palette = UIMenu(title: "", options: [.displayInline, .displayAsPalette], children: actions)
            palette.preferredElementSize = .small
            return palette
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        actions?.menuWillOpen()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        preview()
    }

    /// The message itself, as it is drawn: the bubble with its text, quote and code, and the files above it, cut to their
    /// own outline (the corners and the tail), on nothing.
    private func preview() -> UITargetedPreview? {
        guard let layout, window != nil, !liftedFrames.isEmpty else { return nil }
        let path = ChatMessageCell.liftedPath(layout)
        let parameters = UIPreviewParameters()
        parameters.visiblePath = path
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: body, parameters: parameters)
    }

    /// The outline of what a long press lifts, in the cell's coordinates.
    static func liftedPath(_ layout: ChatMessageLayout) -> UIBezierPath {
        let path = UIBezierPath()
        if let bubble = layout.bubble {
            path.append(ChatBubbleShape.path(in: bubble, mine: layout.isMine, tail: layout.tail))
        }
        for item in layout.files {
            path.append(UIBezierPath(roundedRect: item.frame, cornerRadius: item.isPicture ? 12 : 10))
        }
        return path
    }
}

// MARK: - lines

/// A centred quiet line: a day, a chapter, a note, an answered request, a scheduled run (which opens its prompt).
final class ChatLineCell: UICollectionViewCell {
    static let reuse = ChatCellID.line

    weak var actions: ChatCellActions?
    private var rowID = ""
    private var foldable = false
    private let text = ChatTextView()
    private let symbol = UIImageView()
    private let chevron = UIImageView()
    private let box = UIView()
    private let detail = ChatTextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        box.layer.cornerRadius = 10
        box.layer.cornerCurve = .continuous
        box.backgroundColor = UIColor.Bandito.surface1
        symbol.contentMode = .scaleAspectFit
        chevron.contentMode = .scaleAspectFit
        for view in [box, detail, text, symbol, chevron] as [UIView] { contentView.addSubview(view) }
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityIdentifier = "chat.line"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(row: ChatRow, layout: ChatRowLayout, actions: ChatCellActions) {
        self.actions = actions
        rowID = row.id
        foldable = false
        symbol.isHidden = true
        chevron.isHidden = true
        box.isHidden = true
        detail.isHidden = true
        switch (row.content, layout.payload) {
        case (.line(let line), .line(let payload)):
            text.string = payload.text.string
            text.frame = payload.text.frame
            if let frame = payload.symbol, let name = line.symbol {
                symbol.isHidden = false
                symbol.frame = frame
                symbol.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))
                symbol.tintColor = tint(line.tone)
            }
            if let frame = payload.chevron, let fold = line.fold {
                foldable = true
                chevron.isHidden = false
                chevron.frame = frame
                chevron.image = UIImage(systemName: fold.open ? "chevron.up" : "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
                chevron.tintColor = UIColor.Bandito.text3
            }
            if let boxFrame = payload.detailBox, let item = payload.detail {
                box.isHidden = false
                box.frame = boxFrame
                detail.isHidden = false
                detail.string = item.string
                detail.frame = item.frame
            }
            accessibilityLabel = line.text
            accessibilityTraits = foldable ? .button : .staticText
            accessibilityHint = line.fold == nil ? nil : (line.fold?.open == true ? L10n.Thread.ScheduleRun.folded : L10n.Thread.ScheduleRun.open)
        case (_, .day(let item)):
            text.string = item.string
            text.frame = item.frame
            accessibilityLabel = item.string.string
            accessibilityTraits = .header
            accessibilityHint = nil
        default:
            break
        }
    }

    private func tint(_ tone: ChatLine.Tone) -> UIColor {
        switch tone {
        case .error: UIColor.Bandito.danger
        case .warning: UIColor(AvatarTile.peach)
        case .note, .muted: UIColor.Bandito.text3
        }
    }

    @objc private func tapped() {
        if foldable { actions?.toggleFold(rowID) }
    }
}

// MARK: - tools

/// A folded group of commands: "Ran 7 commands" with the state, opening to a line per command.
final class ChatToolsCell: UICollectionViewCell {
    static let reuse = ChatCellID.tools

    weak var actions: ChatCellActions?
    private var rowID = ""
    private let box = UIView()
    private let icon = UIImageView()
    private let title = ChatTextView()
    private let chevron = UIImageView()
    private let divider = UIView()
    private var lines: [ChatTextView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatToolsCell, _) in
            view.updateColors()
        }
        box.layer.cornerRadius = 10
        box.layer.cornerCurve = .continuous
        box.layer.borderWidth = 0.5
        icon.contentMode = .scaleAspectFit
        chevron.contentMode = .scaleAspectFit
        for view in [box, icon, title, chevron, divider] as [UIView] { contentView.addSubview(view) }
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "chat.tools"
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(row: ChatRow, group: ChatToolGroup, layout: ChatToolsLayout, actions: ChatCellActions) {
        self.actions = actions
        rowID = row.id
        box.frame = layout.box
        title.string = layout.title.string
        title.frame = layout.title.frame
        icon.frame = layout.icon
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        switch group.status {
        case .running:
            icon.image = UIImage(systemName: "circle.dotted", withConfiguration: config)
            icon.tintColor = UIColor.Bandito.text3
        case .failed:
            icon.image = UIImage(systemName: "xmark", withConfiguration: config)
            icon.tintColor = UIColor.Bandito.danger
        case .done:
            icon.image = UIImage(systemName: "checkmark", withConfiguration: config)
            icon.tintColor = UIColor.Bandito.ok
        }
        chevron.frame = layout.chevron
        chevron.image = UIImage(
            systemName: group.open ? "chevron.up" : "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        chevron.tintColor = UIColor.Bandito.text3
        divider.isHidden = !group.open
        divider.frame = CGRect(x: layout.box.minX, y: layout.header.maxY, width: layout.box.width, height: 0.5)
        var index = 0
        for pair in layout.rows {
            for item in [pair.text, pair.summary].compactMap({ $0 }) {
                let view: ChatTextView
                if index < lines.count {
                    view = lines[index]
                } else {
                    view = ChatTextView()
                    lines.append(view)
                    contentView.addSubview(view)
                }
                view.isHidden = false
                view.string = item.string
                view.frame = item.frame
                index += 1
            }
        }
        if index < lines.count { for view in lines[index...] { view.isHidden = true } }
        accessibilityLabel = group.title
        accessibilityHint = group.open ? L10n.Ios.Chat.Tools.hide : L10n.Ios.Chat.Tools.show
        accessibilityValue = group.tools.map(\.title).prefix(group.open ? 60 : 0).joined(separator: ", ")
    }


    private func updateColors() {
        box.layer.borderColor = UIColor.Bandito.line.resolvedColor(with: traitCollection).cgColor
        divider.backgroundColor = UIColor.Bandito.line
    }

    @objc private func tapped() {
        actions?.toggleFold(rowID)
    }
}

// MARK: - changes

/// The card "12 files, +240 −30" at the end of a finished turn; a press opens the list of files.
final class ChatChangesCell: UICollectionViewCell {
    static let reuse = ChatCellID.changes

    weak var actions: ChatCellActions?
    private let card = UIView()
    private let icon = UIImageView()
    private let title = ChatTextView()
    private let stats = ChatTextView()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatChangesCell, _) in
            view.updateColors()
        }
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        icon.contentMode = .scaleAspectFit
        chevron.contentMode = .scaleAspectFit
        for view in [card, icon, title, stats, chevron] as [UIView] { contentView.addSubview(view) }
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "chat.changes"
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(summary: ChatChangesSummary, layout: ChatCardLayout, actions: ChatCellActions) {
        self.actions = actions
        card.frame = layout.card
        title.string = layout.title.string
        title.frame = layout.title.frame
        stats.string = layout.stats.string
        stats.frame = layout.stats.frame
        icon.frame = layout.icon
        icon.image = UIImage(systemName: "plusminus.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        icon.tintColor = UIColor.Bandito.signal
        chevron.frame = layout.chevron
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevron.tintColor = UIColor.Bandito.text3
        accessibilityLabel = L10n.Changes.heading + ": " + summary.line
    }


    private func updateColors() {
        card.backgroundColor = UIColor.Bandito.surface1
        card.layer.borderColor = UIColor.Bandito.line.resolvedColor(with: traitCollection).cgColor
    }

    @objc private func tapped() {
        actions?.openChanges()
    }
}

// MARK: - working

/// The row at the end while the agent's turn runs: three dots that rise in a wave (a Core Animation layer, not a SwiftUI
/// animation), what it does now and how long the turn has run. The time ticks in this cell only.
final class ChatWorkingCell: UICollectionViewCell {
    static let reuse = ChatCellID.working

    private let dotsView = ChatDotsView()
    private let title = ChatTextView()
    private let elapsed = UILabel()
    private var since: Int64?
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        elapsed.font = BanditoFont.uiText(size: 12, weight: 400)
        elapsed.textColor = UIColor.Bandito.text3
        for view in [dotsView, title, elapsed] as [UIView] { contentView.addSubview(view) }
        isAccessibilityElement = true
        accessibilityIdentifier = "chat.working"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(working: ChatWorking, layout: ChatWorkingLayout, reduceMotion: Bool) {
        dotsView.frame = layout.dots
        dotsView.setMoving(!reduceMotion)
        title.string = layout.title.string
        title.frame = layout.title.frame
        elapsed.frame = layout.elapsed
        since = working.since
        accessibilityLabel = working.title
        tick()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil, since != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let seconds = AgentActivity.elapsedSeconds(since: since, now: Date()) {
            elapsed.text = "· " + AgentActivity.elapsedText(seconds: seconds)
        } else {
            elapsed.text = nil
        }
    }
}

/// Three dots that rise one after the other, drawn by Core Animation.
final class ChatDotsView: UIView {
    private var dots: [CALayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChatDotsView, _) in
            view.updateColors()
        }
        for _ in 0..<3 {
            let dot = CALayer()
            dot.cornerRadius = 3
            dots.append(dot)
            layer.addSublayer(dot)
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * 11, y: (bounds.height - 6) / 2, width: 6, height: 6)
        }
    }

    func setMoving(_ moving: Bool) {
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            guard moving else { dot.opacity = 0.7; continue }
            let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
            rise.values = [0, -3.5, 0, 0]
            rise.keyTimes = [0, 0.25, 0.5, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.45, 1, 0.45, 0.45]
            fade.keyTimes = [0, 0.25, 0.5, 1]
            let group = CAAnimationGroup()
            group.animations = [rise, fade]
            group.duration = 1.1
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.14
            group.fillMode = .backwards
            dot.add(group, forKey: "wave")
        }
    }


    private func updateColors() {
        for dot in dots { dot.backgroundColor = UIColor.Bandito.text2.resolvedColor(with: traitCollection).cgColor }
    }
}

// MARK: - hosted

/// A card made in SwiftUI (an approval, a form, a request to connect) inside a cell. The cell reports the card's height
/// when it changes, so the list gives it room.
final class ChatHostedCell: UICollectionViewCell {
    static let reuse = ChatCellID.hosted

    private var host: UIHostingController<AnyView>?
    private(set) var rowID = ""

    func configure(row: ChatRow, content: AnyView, parent: UIViewController) {
        rowID = row.id
        if let host {
            host.rootView = content
        } else {
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            host.sizingOptions = []
            parent.addChild(host)
            contentView.addSubview(host.view)
            host.didMove(toParent: parent)
            self.host = host
        }
        host?.view.frame = contentView.bounds
        host?.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}
