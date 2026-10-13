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
}

// MARK: - message

/// A message: the bubble, the blocks in it (text, code, rules), the pictures and files above it and the small line under
/// it. Views are kept per cell and reused for the next message; the frames come from the measured layout.
final class ChatMessageCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    static let reuse = ChatCellID.message

    weak var actions: ChatCellActions?
    private(set) var rowID = ""
    private var message: ChatMessage?
    private var layout: ChatMessageLayout?

    private let senderView = ChatTextView()
    private let bubble = ChatBubbleView()
    private let metaView = ChatTextView()
    private var texts: [ChatTextView] = []
    private var codes: [ChatCodeBlockView] = []
    private var plains: [UIView] = []
    private var pictures: [ChatPictureView] = []
    private var chips: [ChatFileChipView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(senderView)
        contentView.addSubview(bubble)
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
                view.backgroundColor = UIColor.Bandito.line
            case .bar(let rect):
                let view = take(&plains, plainIndex) { UIView() }
                plainIndex += 1
                view.frame = rect
                view.layer.cornerRadius = 1.5
                view.backgroundColor = UIColor.Bandito.lineStrong
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
        contentView.addSubview(view)
        return view
    }

    private func hide<V: UIView>(_ pool: [V], from index: Int) {
        guard index < pool.count else { return }
        for view in pool[index...] { view.isHidden = true }
    }

    private func customActions(for message: ChatMessage) -> [UIAccessibilityCustomAction] {
        var found = [
            UIAccessibilityCustomAction(name: L10n.Thread.copy) { [weak self] _ in
                guard let self, let layout = self.layout else { return false }
                self.actions?.copy(layout.plain)
                return true
            }
        ]
        switch message.caption {
        case .notDelivered(let seq)?:
            found.append(
                UIAccessibilityCustomAction(name: L10n.Message.resend) { [weak self] _ in
                    self?.actions?.resend(seq: seq)
                    return true
                })
        case .notSent(let id)?:
            found.append(
                UIAccessibilityCustomAction(name: L10n.Ios.Chat.retry) { [weak self] _ in
                    self?.actions?.retry(queueID: id)
                    return true
                })
            found.append(
                UIAccessibilityCustomAction(name: L10n.Ios.Chat.discard) { [weak self] _ in
                    self?.actions?.discard(queueID: id)
                    return true
                })
        default:
            break
        }
        return found
    }

    // MARK: touches

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: contentView)
        if let url = link(at: point) {
            actions?.openLink(url)
            return
        }
        guard let message, let meta = layout?.meta, meta.frame.insetBy(dx: -12, dy: -10).contains(point) else { return }
        switch message.caption {
        case .notDelivered(let seq)?: actions?.resend(seq: seq)
        case .notSent(let id)?: actions?.retry(queueID: id)
        default: break
        }
    }

    private func link(at point: CGPoint) -> URL? {
        for view in texts where !view.isHidden {
            if let url = view.link(at: contentView.convert(point, to: view)) { return url }
        }
        return nil
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let message, let layout, message.caption.map({ if case .notSent = $0 { return false } else { return true } }) ?? true
        else { return nil }
        let url = link(at: location)
        let body = message.text
        let isMarkdown = message.markdown && body != layout.plain
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var items: [UIMenuElement] = []
            if let url {
                items.append(
                    UIAction(title: L10n.Ios.Chat.openInSafari, image: UIImage(systemName: "safari")) { _ in
                        self?.actions?.openLink(url)
                    })
                items.append(
                    UIAction(title: L10n.Ios.Chat.copyLink, image: UIImage(systemName: "link")) { _ in
                        self?.actions?.copy(url.absoluteString)
                    })
            }
            items.append(
                UIAction(title: L10n.Thread.copy, image: UIImage(systemName: "doc.on.doc")) { _ in
                    self?.actions?.copy(layout.plain)
                })
            if isMarkdown {
                items.append(
                    UIAction(title: L10n.Thread.copyMarkdown, image: UIImage(systemName: "text.alignleft")) { _ in
                        self?.actions?.copy(body)
                    })
            }
            return UIMenu(children: items)
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        guard let frame = layout?.bubble else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerRadius: 16)
        let target = UIPreviewTarget(container: contentView, center: CGPoint(x: frame.midX, y: frame.midY))
        let view = bubble
        return UITargetedPreview(view: view, parameters: parameters, target: target)
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
