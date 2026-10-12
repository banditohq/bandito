#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// A cell of the thread's list that draws a native row (see `NativeRow`).
final class NativeRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("thread-native-row")

    weak var list: ThreadListView?
    private(set) var row: NativeRow?
    private var context: ThreadListContext?
    private let message = NativeMessageView()
    private let label = NativeLabelView()
    private let tools = NativeToolGroupView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        for view in [message, label, tools] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
        message.cell = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ row: NativeRow, context: ThreadListContext) {
        self.context = context
        message.context = context
        guard row != self.row else { return }
        self.row = row
        tools.isHidden = true
        switch row {
        case .message(let spec):
            label.isHidden = true
            message.isHidden = false
            message.show(spec)
        case .tools(let key, let title, let failed):
            message.isHidden = true
            label.isHidden = true
            tools.isHidden = false
            tools.show(key: key, title: title, failed: failed) { [weak self] in
                guard let self else { return }
                self.list?.reload(self)
            }
        case .day(let caption):
            message.isHidden = true
            label.isHidden = false
            label.show(text: caption, size: 11.5, weight: 500, color: Color.Bandito.text3, padding: 6, selectable: false)
        case .note(let text, let isError):
            message.isHidden = true
            label.isHidden = false
            label.show(
                text: text, size: 12, weight: 400, color: isError ? Color.Bandito.danger : Color.Bandito.text3,
                padding: 2, selectable: true)
        }
        needsLayout = true
    }

    /// The height of the row at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        switch row {
        case .message?: message.geometry(forWidth: width).height
        case .day?, .note?: label.height(forWidth: width) + ThreadListView.rowSpacing
        case .tools?: NativeToolGroupView.height + ThreadListView.rowSpacing
        case nil: 1
        }
    }

    override func layout() {
        super.layout()
        // Only the part that shows is laid out, and only when its size changed.
        let shown: NSView = !tools.isHidden ? tools : message.isHidden ? label : message
        if shown.frame != bounds { shown.frame = bounds }
    }

    /// The bubble's frame in the cell, for the actions under it.
    var bubbleFrame: CGRect? {
        guard case .message = row, !message.isHidden else { return nil }
        return message.bubbleFrame
    }

    var messageSpec: NativeMessageSpec? {
        if case .message(let spec) = row { spec } else { nil }
    }

    fileprivate func hoverChanged(_ inside: Bool) {
        list?.nativeHover(self, inside: inside)
    }

    func selectText() { message.selectText() }
}

/// A centred caption: a day, or a note (selectable), in the line's column.
final class NativeLabelView: NSView {
    private let text = NativeTextView.make()
    private var padding: CGFloat = 0
    /// The text's size for the last width it was measured at.
    private var measured: (width: CGFloat, size: CGSize)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(text value: String, size: CGFloat, weight: Int, color: Color, padding: CGFloat, selectable: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.textStorage?.setAttributedString(
            NSAttributedString(
                string: value,
                attributes: [
                    .font: BanditoFont.appKitText(size: size, weight: weight), .foregroundColor: NSColor(color),
                    .paragraphStyle: paragraph,
                ]))
        text.isSelectable = selectable
        self.padding = padding
        measured = nil
        needsLayout = true
    }

    /// The text's own size in the column of a cell `width` wide (its widest line, its height).
    private func textSize(_ width: CGFloat) -> CGSize {
        let inner = max(1, NativeMessageGeometry.column(width).width)
        if let measured, abs(measured.width - inner) < 0.5 { return measured.size }
        let size = NativeRowText.size(of: text.textStorage ?? NSAttributedString(), width: inner)
        measured = (inner, size)
        return size
    }

    func height(forWidth width: CGFloat) -> CGFloat { textSize(width).height + padding * 2 }

    override func layout() {
        super.layout()
        // As SwiftUI centres a `Text`: the text's own frame, in the middle, on a half point.
        let (x, width) = NativeMessageGeometry.column(bounds.width)
        let size = textSize(bounds.width)
        let left = ((x + (width - size.width) / 2) * 2).rounded() / 2
        let frame = CGRect(x: left, y: padding, width: size.width + 0.01, height: size.height)
        if text.frame != frame {
            text.wrapWidth = frame.width
            text.frame = frame
        }
    }
}

/// A folded group of finished tool calls: "Ran 3 commands" with a check (or a cross), and a chevron. A click opens it,
/// and the open group is the SwiftUI card (`ToolGroupCard`). Drawn with the card's metrics: 28 pt high in the line's
/// column, 10 pt of padding, 8 pt between the parts, a 0.5 pt edge with 7 pt corners, a 5 % fill on hover.
final class NativeToolGroupView: NSView {
    static let height: CGFloat = 28
    private var key = ""
    private var title = ""
    private var failed = false
    private var hovering = false
    private var onToggle: () -> Void = {}
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(key: String, title: String, failed: Bool, onToggle: @escaping () -> Void) {
        self.key = key
        self.title = title
        self.failed = failed
        self.onToggle = onToggle
        hovering = false
        setAccessibilityLabel(title)
        needsDisplay = true
    }

    private var box: CGRect {
        let (x, width) = NativeMessageGeometry.column(bounds.width)
        return CGRect(x: x, y: 0, width: width, height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = box
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if hovering {
            NSColor(Color.Bandito.text.opacity(0.05)).setFill()
            NSBezierPath(cgPath: shape.path(in: box).cgPath).fill()
        }
        let edge = NSBezierPath(cgPath: shape.path(in: box.insetBy(dx: 0.25, dy: 0.25)).cgPath)
        edge.lineWidth = 0.5
        NSColor(Color.Bandito.line).setStroke()
        edge.stroke()
        // The status: a bold check (or cross) at 10 pt in a 13 pt column.
        let symbol = NSImage(systemSymbolName: failed ? "xmark" : "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        var x = box.minX + 10
        if let symbol {
            draw(symbol, tint: NSColor(failed ? Color.Bandito.danger : Color.Bandito.ok), centeredIn: CGRect(x: x, y: 0, width: 13, height: box.height))
        }
        x += 13 + 8
        let text = NSAttributedString(
            string: title,
            attributes: [.font: BanditoFont.appKitText(size: 12, weight: 500), .foregroundColor: NSColor(Color.Bandito.text2)])
        let size = text.size()
        text.draw(at: CGPoint(x: x, y: (box.height - size.height) / 2))
        // The chevron, turned to point right while the group is folded.
        if let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        {
            let width = chevron.size.width
            draw(chevron, tint: NSColor(Color.Bandito.text3), centeredIn: CGRect(x: box.maxX - 10 - max(width, 9), y: 0, width: max(width, 9), height: box.height))
        }
    }

    private func draw(_ image: NSImage, tint: NSColor, centeredIn rect: CGRect) {
        let size = image.size
        let tinted = NSImage(size: size, flipped: false) { bounds in
            image.draw(in: bounds)
            tint.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let y = rect.midY - size.height / 2
        tinted.draw(in: CGRect(x: rect.midX - size.width / 2, y: y, width: size.width, height: size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: box, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        if ThreadScrollActivity.isScrolling() { return }
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard box.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    private func toggle() {
        ThreadDisclosure.shared.toggle(key)
        onToggle()
    }
}

/// A message: the bubble (a layer of the SwiftUI bubble's own shape), its texts in text views (selectable, with
/// links), and its code blocks.
final class NativeMessageView: NSView {
    weak var cell: NativeRowCell?
    var context: ThreadListContext?
    private(set) var spec: NativeMessageSpec?
    private var blocks: [NativeBlock] = []
    private var blockViews: [NSView] = []
    private var measured: (width: CGFloat, geometry: NativeMessageGeometry)?
    /// The blocks' sizes the geometry was made from (a scrolling code block's is its one-line width).
    private var measuredSizes: [CGSize] = []
    private let fill = CAShapeLayer()
    private let tint = CAShapeLayer()
    private let edge = CAShapeLayer()
    private let flash = CAShapeLayer()
    private var tracking: NSTrackingArea?
    /// What the last layout was made for: the width and the content.
    private var laidOut: (width: CGFloat, version: Int)?
    private var version = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [flash, fill, tint, edge] {
            shape.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "fillColor": NSNull()]
            layer?.addSublayer(shape)
        }
        edge.fillColor = nil
        edge.lineWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ spec: NativeMessageSpec) {
        let textChanged = spec.text != self.spec?.text || spec.fromUser != self.spec?.fromUser
            || spec.streaming != self.spec?.streaming
        self.spec = spec
        if textChanged {
            blocks = NativeMessageBlocks.make(spec)
            measured = nil
            rebuildBlockViews()
        }
        if textChanged { version &+= 1 }
        updateColors()
        setFlash(spec.flashing)
        needsLayout = true
    }

    func geometry(forWidth width: CGFloat) -> NativeMessageGeometry {
        if let measured, abs(measured.width - width) < 0.5 { return measured.geometry }
        // A finished message was most likely measured already, off the main thread (`NativeSizeCache.prefetch`).
        var sizes: [CGSize]
        if let spec, !spec.streaming {
            let key = NativeSizeCache.Key(spec, width: width)
            if let cached = NativeSizeCache.shared.sizes(for: key), cached.count == blocks.count {
                sizes = cached
            } else {
                sizes = NativeMessageBlocks.sizes(blocks, cellWidth: width)
                NativeSizeCache.shared.store(sizes, for: key)
            }
        } else {
            sizes = NativeMessageBlocks.sizes(blocks, cellWidth: width)
        }
        let geometry = NativeMessageGeometry.make(
            cellWidth: width, fromUser: spec?.fromUser ?? false, streaming: spec?.streaming ?? false,
            markdown: !(spec?.fromUser ?? false), sizes: sizes, code: NativeMessageBlocks.isCode(blocks))
        measured = (width, geometry)
        measuredSizes = sizes
        return geometry
    }

    var bubbleFrame: CGRect { geometry(forWidth: bounds.width).bubble }

    private func rebuildBlockViews() {
        // Views are kept by kind and reused in order: a stream changes the text of its last block at every token.
        var texts = blockViews.compactMap { $0 as? NativeTextView }
        var codes = blockViews.compactMap { $0 as? NativeCodeBlockView }
        var next: [NSView] = []
        for block in blocks {
            switch block {
            case .text(let text):
                let view = texts.isEmpty ? NativeTextView.make() : texts.removeFirst()
                view.owner = self
                if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
                next.append(view)
            case .code(let language, let code, let text, let scrolls):
                let view = codes.isEmpty ? NativeCodeBlockView() : codes.removeFirst()
                view.show(language: language, code: code, text: text, scrolls: scrolls, owner: self)
                next.append(view)
            }
        }
        for view in texts as [NSView] + codes as [NSView] { view.removeFromSuperview() }
        for view in next where view.superview !== self { addSubview(view) }
        blockViews = next
    }

    private var coloured: (fromUser: Bool, accent: Color, appearance: NSAppearance.Name)?

    private func updateColors() {
        guard let spec else { return }
        let appearance = effectiveAppearance
        if let coloured, coloured.fromUser == spec.fromUser, coloured.accent == spec.accent,
            coloured.appearance == appearance.name
        {
            return
        }
        coloured = (spec.fromUser, spec.accent, appearance.name)
        if spec.fromUser {
            fill.fillColor = NativeColors.cg(Color.Bandito.surface2, in: appearance)
            tint.fillColor = NativeColors.cg(BubbleLook.userTint, in: appearance)
            edge.strokeColor = NativeColors.cg(BubbleLook.userBorder, in: appearance)
            tint.isHidden = false
        } else {
            fill.fillColor = NativeColors.cg(Color.Bandito.surface1, in: appearance)
            edge.strokeColor = NativeColors.cg(BubbleLook.agentBorder, in: appearance)
            tint.isHidden = true
        }
        flash.fillColor = NativeColors.cg(spec.accent.opacity(0.2), in: appearance)
    }

    private func setFlash(_ on: Bool) {
        let target: Float = on ? 1 : 0
        guard flash.opacity != target else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = flash.presentation()?.opacity ?? flash.opacity
        animation.toValue = target
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(animation, forKey: "flash")
        flash.opacity = target
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        coloured = nil
        updateColors()
    }

    override func layout() {
        super.layout()
        guard let spec else { return }
        if let laidOut, laidOut.width == bounds.width, laidOut.version == version { return }
        laidOut = (bounds.width, version)
        let geometry = geometry(forWidth: bounds.width)
        let bubble = geometry.bubble
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = BubbleLook.shape(fromUser: spec.fromUser).path(in: CGRect(origin: .zero, size: bubble.size)).cgPath
        for shape in [fill, tint, edge] {
            shape.frame = bubble
            shape.path = path
        }
        let around = bubble.insetBy(dx: -6, dy: -6)
        flash.frame = around
        flash.path = RoundedRectangle(cornerRadius: 22, style: .continuous)
            .path(in: CGRect(origin: .zero, size: around.size)).cgPath
        CATransaction.commit()
        let wrap = NativeMessageGeometry.textWidth(cellWidth: bounds.width)
        for (index, (view, frame)) in zip(blockViews, geometry.blocks).enumerated() {
            (view as? NativeTextView)?.wrapWidth = wrap
            if let code = view as? NativeCodeBlockView, index < measuredSizes.count {
                code.scrollWidth = measuredSizes[index].width
            }
            view.frame = frame.offsetBy(dx: bubble.minX, dy: bubble.minY)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard let spec, !spec.streaming else { return }
        let area = NSTrackingArea(
            rect: bubbleFrame, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        // Content moving under a still pointer reports hover again and again: while the thread scrolls, rows do not
        // light up (as the SwiftUI rows).
        if ThreadScrollActivity.isScrolling() { return }
        cell?.hoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) { cell?.hoverChanged(false) }

    override func mouseMoved(with event: NSEvent) { cell?.hoverChanged(true) }

    // MARK: Clicks and menu

    override func mouseDown(with event: NSEvent) {
        // A double click on the agent's bubble (its padding, not the text) likes the message.
        if event.clickCount == 2, let spec, !spec.fromUser, bubbleFrame.contains(convert(event.locationInWindow, from: nil)) {
            NativeMessageActions(spec: spec, context: context).toggleLike()
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let spec, !spec.streaming else { return nil }
        guard bubbleFrame.contains(convert(event.locationInWindow, from: nil)) else { return nil }
        return NativeMessageActions(spec: spec, context: context).menu(selectText: { [weak self] in self?.selectText() })
    }

    /// The text view of a block asks for the menu of the message.
    func menuForText(_ event: NSEvent) -> NSMenu? {
        guard let spec, !spec.streaming else { return nil }
        return NativeMessageActions(spec: spec, context: context).menu(selectText: { [weak self] in self?.selectText() })
    }

    func openLink(_ url: URL) {
        context?.openLink(url)
    }

    /// The whole text in a panel with everything selected (the menu's "Select text").
    func selectText() {
        guard let spec else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SelectableTextPanel(text: spec.text))
        popover.show(relativeTo: bubbleFrame, of: self, preferredEdge: .maxY)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let spec, !spec.streaming else { return nil }
        return NativeMessageActions(spec: spec, context: context).accessibilityActions()
    }
}

/// A selectable, linked text of a native message. Its menu is the message's.
final class NativeTextView: NSTextView {
    weak var owner: NativeMessageView?
    /// The width the text wraps at: the width it was measured with, not its frame (a frame exactly as wide as the
    /// widest line wrapped its last word).
    var wrapWidth: CGFloat = 0 {
        didSet { textContainer?.containerSize = CGSize(width: max(frame.width, wrapWidth), height: .greatestFiniteMagnitude) }
    }

    static func make() -> NativeTextView {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        let view = NativeTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        // The links keep the colours of their runs (see `NativeRowText.running`); no underline.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = view
        return view
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menuForText(event) ?? super.menu(for: event)
    }

    /// VoiceOver's actions on the text are the message's (copy, reply, the reactions).
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        owner?.accessibilityCustomActions() ?? super.accessibilityCustomActions()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if textContainer?.containerSize.width != CGFloat.greatestFiniteMagnitude {
            textContainer?.containerSize = CGSize(width: max(newSize.width, wrapWidth), height: .greatestFiniteMagnitude)
        }
    }
}

extension NativeTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        owner?.openLink(url)
        return true
    }
}

/// A fenced code block of a native message: the language, a Copy button, the code (a long line scrolls sideways).
final class NativeCodeBlockView: NSView {
    private var language = ""
    private let copy = NativeCopyButton()
    private let text = NativeTextView.make()
    private let scroll = NSScrollView()
    private var scrolls = false
    /// The width of the code on one line (a scrolling block): measured with the message (`NativeMessageBlocks.sizes`).
    var scrollWidth: CGFloat?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        addSubview(copy)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        addSubview(scroll)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(language name: String?, code: String, text value: NSAttributedString, scrolls: Bool, owner: NativeMessageView) {
        language = name ?? ""
        needsDisplay = true
        copy.code = code
        text.owner = owner
        if text.textStorage?.isEqual(to: value) != true { text.textStorage?.setAttributedString(value) }
        self.scrolls = scrolls
        if scrolls {
            text.removeFromSuperview()
            scroll.documentView = text
            scroll.isHidden = false
            text.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        } else {
            if scroll.documentView === text { scroll.documentView = nil }
            scroll.isHidden = true
            text.textContainer?.containerSize = CGSize(width: max(1, text.wrapWidth), height: .greatestFiniteMagnitude)
            if text.superview !== self { addSubview(text) }
        }
        needsLayout = true
    }

    /// The language in the corner: JetBrains Mono 11, 500, `text3`, centred on the header row, cut with an ellipsis.
    override func draw(_ dirtyRect: NSRect) {
        guard !language.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(
            string: language,
            attributes: [
                .font: BanditoFont.appKitMono(size: 11, weight: 500), .foregroundColor: NSColor(Color.Bandito.text3),
                .paragraphStyle: paragraph,
            ])
        let height = text.size().height
        let inset = NativeMessageGeometry.codeInset
        text.draw(
            with: CGRect(x: inset, y: 6 + (24 - height) / 2, width: max(0, copy.frame.minX - 8 - inset), height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func updateColors() {
        layer?.backgroundColor = NativeColors.cg(Color.Bandito.bg, in: effectiveAppearance)
        layer?.borderColor = NativeColors.cg(Color.Bandito.line, in: effectiveAppearance)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        let inset = NativeMessageGeometry.codeInset
        let copySize = copy.intrinsicContentSize
        copy.frame = CGRect(x: bounds.width - 6 - copySize.width, y: 6, width: copySize.width, height: 24)
        let codeTop: CGFloat = 6 + 24 + 4
        let codeHeight = bounds.height - codeTop - 12
        if scrolls {
            scroll.frame = CGRect(x: 0, y: codeTop, width: bounds.width, height: codeHeight + 12)
            text.frame = CGRect(x: 0, y: 0, width: (scrollWidth ?? 0) + inset * 2, height: codeHeight)
            text.textContainerInset = NSSize(width: inset, height: 0)
        } else {
            text.textContainerInset = .zero
            text.wrapWidth = bounds.width - inset * 2
            text.frame = CGRect(x: inset, y: codeTop, width: bounds.width - inset * 2, height: codeHeight)
        }
    }
}

/// The Copy button of a code block: an icon and a word, lit on hover, "Copied" in green for a moment. Drawn, with the
/// metrics of the SwiftUI button: 8 pt padding, 5 pt between the icon (11 pt, medium) and the word (Onest 11.5, 500).
final class NativeCopyButton: NSView {
    var code = ""
    private var hovering = false
    private var copied = false
    private var reset: DispatchWorkItem?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        toolTip = L10n.Thread.copy
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
        setAccessibilityLabel(L10n.Thread.copy)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var color: NSColor { NSColor(copied ? Color.Bandito.ok : Color.Bandito.text2) }

    private var icon: NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        return NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private var word: NSAttributedString {
        NSAttributedString(
            string: copied ? L10n.Message.copied : L10n.Thread.copy,
            attributes: [.font: BanditoFont.appKitText(size: 11.5, weight: 500), .foregroundColor: color])
    }

    private static var widths: [Bool: CGFloat] = [:]

    override var intrinsicContentSize: NSSize {
        if let width = Self.widths[copied] { return NSSize(width: width, height: 24) }
        let width = 8 + (icon?.size.width ?? 12) + 5 + word.size().width + 8
        Self.widths[copied] = width
        return NSSize(width: width, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let icon {
            let size = icon.size
            let tinted = NSImage(size: size, flipped: false) { rect in
                icon.draw(in: rect)
                self.color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(x: 8, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        let text = word
        let size = text.size()
        text.draw(at: CGPoint(x: 8 + (icon?.size.width ?? 12) + 5, y: (bounds.height - size.height) / 2))
    }

    private func refresh() {
        layer?.backgroundColor =
            hovering ? NativeColors.cg(Color.Bandito.text.opacity(0.07), in: effectiveAppearance) : nil
        setAccessibilityLabel(copied ? L10n.Message.copied : L10n.Thread.copy)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

    private func press() {
        SystemActions.copy(code)
        copied = true
        refresh()
        reset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copied = false
            self?.refresh()
        }
        reset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// What a person does to a native message, as the SwiftUI row offers it (`MessageContainer`): reply, react, copy,
/// copy as text, select, read aloud.
@MainActor
struct NativeMessageActions {
    var spec: NativeMessageSpec
    var context: ThreadListContext?

    private var chat: ThreadChat? { context?.chat }
    var canReact: Bool { (chat?.reactionsOn ?? false) && spec.seq != nil }
    var canReply: Bool { (chat?.repliesOn ?? false) && spec.seq != nil }
    var mine: String? { spec.seq.flatMap { chat?.reactions[$0]?.mine } }
    var reading: Bool { SpeechOutput.shared.speakingKey == spec.id }

    func reply() {
        guard let seq = spec.seq else { return }
        chat?.onReply(ReplyTarget(seq: seq, fromUser: spec.fromUser, text: spec.text))
    }

    func react(_ emoji: String?) {
        guard let seq = spec.seq else { return }
        chat?.onReact(seq, emoji)
    }

    func toggleLike() {
        guard canReact else { return }
        react(mine == ReactionRules.common[0] ? nil : ReactionRules.common[0])
    }

    func copyRaw() { SystemActions.copy(spec.text) }

    func copyPlain() { SystemActions.copy(MessageBlocks.plainText(spec.text)) }

    func toggleReading() {
        if reading {
            SpeechOutput.shared.stop()
            return
        }
        let spoken = SpeechText.plain(spec.text, codeSkipped: L10n.Speech.codeSkipped)
        let voice = SpeechLanguage.voiceTag(for: spoken, appLanguage: SpeechLanguage.appLanguage)
        SpeechOutput.shared.speak(spoken, key: spec.id, voiceTag: voice)
    }

    func menu(selectText: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        if canReply { menu.addItem(NativeMenuItem(L10n.Thread.reply, reply)) }
        if canReact {
            let react = NSMenuItem(title: L10n.Message.react, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for emoji in ReactionRules.common {
                sub.addItem(NativeMenuItem(emoji) { [self] in self.react(emoji == mine ? nil : emoji) })
            }
            react.submenu = sub
            menu.addItem(react)
        }
        if canReply || canReact { menu.addItem(.separator()) }
        menu.addItem(NativeMenuItem(L10n.Thread.copy, copyRaw))
        menu.addItem(NativeMenuItem(L10n.Message.copyAsText, copyPlain))
        menu.addItem(NativeMenuItem(L10n.Message.selectText, selectText))
        if !spec.fromUser {
            menu.addItem(NativeMenuItem(reading ? L10n.Speech.stop : L10n.Speech.read, toggleReading))
        }
        return menu
    }

    func accessibilityActions() -> [NSAccessibilityCustomAction] {
        var actions = [NSAccessibilityCustomAction(name: L10n.Thread.copy) { copyRaw(); return true }]
        if canReply { actions.append(NSAccessibilityCustomAction(name: L10n.Thread.reply) { reply(); return true }) }
        if canReact {
            for emoji in ReactionRules.common {
                actions.append(
                    NSAccessibilityCustomAction(name: "\(L10n.Message.react) \(emoji)") {
                        react(emoji == mine ? nil : emoji)
                        return true
                    })
            }
        }
        return actions
    }
}

/// A menu item that runs a closure.
final class NativeMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
#endif
