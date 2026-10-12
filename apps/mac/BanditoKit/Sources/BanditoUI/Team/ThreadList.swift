#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import SwiftUI

// The rows of a thread in an AppKit table. A SwiftUI stack of rows in a SwiftUI scroll view measured, laid out and
// updated the whole window of rows at every step of a scroll; here a scroll moves layers and costs the main thread
// nothing until a row comes into view, and then only that row is made (cells are reused). The rows themselves are the
// same SwiftUI views (`EquatableThreadRow`), each in a hosting view of its own: bubbles, text selection, context menus,
// reactions, popovers and the hover row work as before.
//
// `ThreadView` drives it through `ThreadListController` (scroll to the bottom, to a row, where the top row is) and hears
// the scroll metrics from it, so the rules of following the bottom and of the "down" button stay in `ThreadScroll`.

/// One line of the list: a row of the thread, or the typing indicator under the last one.
enum ThreadListLine: Equatable, Identifiable {
    case row(ThreadRowKey, live: Bool)
    case typing(AgentActivity, since: Int64?)

    var id: String {
        switch self {
        case .row(let key, _): key.row.id
        case .typing: ThreadListLine.typingID
        }
    }

    static let typingID = "typing"

    /// What VoiceOver reads for the row as a whole: the message's text (its controls are read inside it).
    var accessibilityText: String? {
        guard case .row(let key, _) = self, case .item(let item) = key.row else { return nil }
        switch item {
        case .user(_, let text, _, _, _, _), .assistant(_, let text, _), .streaming(let text):
            return text.isEmpty ? nil : String(text.prefix(400))
        default:
            return nil
        }
    }

    /// The id of the agent's newest reply: its row offers the quick actions.
    static func lastAgentID(in items: [ThreadItem]) -> String? {
        items.last(where: { item in
            if case .assistant = item { return true }
            return false
        })?.id
    }
}

/// What changed in the lines since the list last had them: nothing, only the last one (a stream), or anything.
enum ThreadRowsChange: Equatable {
    case none, last, all
}

/// How the list goes from one set of line ids to the next without reloading what stays.
enum ThreadListDiff: Equatable {
    /// The same ids: only contents changed.
    case same
    /// The head of the list changed and the rest stayed (older history read: its rows come above, and the day line
    /// on top may be made again). `removed` lines at the top go, `inserted` come in their place.
    case head(removed: Int, inserted: Int)
    /// The tail changed and the rest stayed (a new message, the typing line, a stream that got its final id).
    case tail(removed: Int, inserted: Int)
    /// Nothing in common worth keeping.
    case reload

    static func of(old: [String], new: [String]) -> ThreadListDiff {
        if old == new { return .same }
        guard !old.isEmpty, !new.isEmpty else { return .reload }
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
        // The longer kept part decides; a list with nothing kept is made again.
        if prefix >= suffix, prefix > 0 {
            return .tail(removed: old.count - prefix, inserted: new.count - prefix)
        }
        if suffix > 0 {
            return .head(removed: old.count - suffix, inserted: new.count - suffix)
        }
        return .reload
    }
}

/// What every row needs besides its key: the server and the actions, which do not decide how a row looks.
struct ThreadListContext {
    var server: ServerModel
    /// Opens a link of a message (a file path or a web address) as the chat does.
    var openLink: (URL) -> Void = { _ in }
    /// The agent whose rows these are: another one is another thread (row ids repeat between agents).
    var agentID: String
    var chat: ThreadChat
    var onError: (UserFacingMessage) -> Void
}

/// How `ThreadView` moves the list and reads it.
@MainActor
final class ThreadListController {
    fileprivate weak var list: ThreadListView?
    /// The list moved or changed its size: the new metrics (offset, height of the content and of the screen).
    var onMetrics: ((ThreadScrollMetrics) -> Void)?
    /// The top of the content came within `ThreadScroll.topSlack` (older history is to be read).
    var onNearTop: (() -> Void)?

    /// Whether the list is in a window.
    var isLive: Bool { list?.window != nil }

    /// Brings the end of the last row on screen, sliding when `slide` is given.
    func scrollToBottom(slide: ThreadSlide?) { list?.scrollToBottom(slide: slide) }

    /// Brings the row `id` to the top or the middle of the screen.
    func scroll(to id: String, centered: Bool, slide: ThreadSlide?) {
        list?.scroll(to: id, centered: centered, slide: slide)
    }

    /// The row on top of what shows.
    func topRowID() -> String? { list?.topRowID() }

    var metrics: ThreadScrollMetrics? { list?.metrics }
}

/// The list in SwiftUI: the lists of the last few agents shown, the current one on screen (see `ThreadListHost`).
struct ThreadList: NSViewRepresentable {
    var lines: ThreadListLines
    /// The version of `lines`: what SwiftUI compares.
    var version: Int
    var context: ThreadListContext
    var controller: ThreadListController

    func makeNSView(context: Context) -> ThreadListHost {
        let host = ThreadListHost()
        updateNSView(host, context: context)
        return host
    }

    func updateNSView(_ host: ThreadListHost, context: Context) {
        let list = host.show(agentID: self.context.agentID, controller: controller)
        controller.list = list
        list.update(lines: lines.lines, change: lines.change, version: version, context: self.context)
    }
}

/// Keeps the lists of the last agents shown, each with its cells made and measured and its place: going back to one of
/// them shows it at once, where it was left, instead of making its rows again (5–8 ms a row without a GPU). Only the
/// current one is on screen and reports to the controller; the oldest goes when a fifth agent comes.
final class ThreadListHost: NSView {
    static let kept = 4
    /// Most recent last.
    private var lists: [(agentID: String, view: ThreadListView)] = []

    func show(agentID: String, controller: ThreadListController) -> ThreadListView {
        if let index = lists.firstIndex(where: { $0.agentID == agentID }) {
            lists.append(lists.remove(at: index))
        } else {
            let view = ThreadListView()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            lists.append((agentID, view))
            if lists.count > Self.kept { lists.removeFirst().view.removeFromSuperview() }
        }
        let current = lists[lists.count - 1].view
        for entry in lists {
            let shown = entry.view === current
            if entry.view.isHidden == shown { entry.view.isHidden = !shown }
            entry.view.controller = shown ? controller : nil
        }
        return current
    }
}

/// The scroll view with its table.
final class ThreadListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    weak var controller: ThreadListController?
    private let table = ThreadTableView()
    private var lines: [ThreadListLine] = []
    private var context: ThreadListContext?
    /// Measured heights of rows at `measuredWidth`, by line id.
    private var heights: [String: CGFloat] = [:]
    /// The guessed heights of rows not measured yet, by line id: the table asks for every row's height (a long
    /// thread's 1500 rows) at each reload and each width; a guess is made once per line.
    private var guesses: [String: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    /// The rows whose measured height differs from the one the table has; told to the table once per pass.
    private var pendingHeights = IndexSet()
    private var heightsScheduled = false
    private var lastMetrics: ThreadScrollMetrics?
    private var nearTop = false
    /// A scroll asked for before the list had a size (a thread just shown): done at the first layout with one.
    private var pendingScroll: (() -> Void)?

    /// The space above the first row and below the last one, and between two rows.
    static let topInset: CGFloat = 22
    static let bottomInset: CGFloat = 12
    static let rowSpacing: CGFloat = 12

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: Self.topInset, left: 0, bottom: Self.bottomInset, right: 0)
        verticalScrollElasticity = .allowed
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.gridStyleMask = []
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.frameDidChangeNotification, object: table)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: rows

    private var version = -1

    func update(lines new: [ThreadListLine], change: ThreadRowsChange, version next: Int, context: ThreadListContext) {
        let switched = self.context.map { $0.agentID != context.agentID } ?? false
        self.context = context
        if switched {
            // Another agent's thread: nothing measured or guessed for the last one holds (its row ids repeat here).
            version = next
            heights.removeAll()
            guesses.removeAll()
            lines = new
            table.prepareOnlyVisible()
            table.reloadData()
            return
        }
        guard next != version else { return }
        version = next
        let old = lines
        if change != .last { NativeSizeCache.shared.prefetch(new, width: table.bounds.width) }
        if old.isEmpty { table.prepareOnlyVisible() }
        if change == .last, new.count == old.count, !new.isEmpty {
            // A stream: only the last row is given its new content.
            lines = new
            guesses[new[new.count - 1].id] = nil
            reconfigure(IndexSet(integer: new.count - 1))
            return
        }
        guard new != old else { return }
        switch ThreadListDiff.of(old: old.map(\.id), new: new.map(\.id)) {
        case .same:
            // Same rows: the ones whose content changed are reconfigured (a stream, a reaction, a flash).
            lines = new
            var changed = IndexSet()
            for index in new.indices where new[index] != old[index] { changed.insert(index) }
            reconfigure(changed)
        case .tail(let removed, let inserted):
            // The rows before the end are kept; the end is replaced (a new message, the typing line, a stream that
            // got its final id).
            lines = new
            let kept = old.count - removed
            var changed = IndexSet()
            for index in 0..<kept where new[index] != old[index] { changed.insert(index) }
            table.beginUpdates()
            if removed > 0 { table.removeRows(at: IndexSet(integersIn: kept..<old.count), withAnimation: []) }
            if inserted > 0 { table.insertRows(at: IndexSet(integersIn: kept..<new.count), withAnimation: []) }
            table.endUpdates()
            reconfigure(changed)
        case .head(let removed, let inserted):
            // Rows put above (older history, its day line made again): what shows stays where it is. The offset moves
            // by what the head grew.
            let before = contentView.bounds.origin.y
            let oldHead = removed > 0 ? table.rect(ofRow: removed - 1).maxY : 0
            lines = new
            table.beginUpdates()
            if removed > 0 { table.removeRows(at: IndexSet(integersIn: 0..<removed), withAnimation: []) }
            if inserted > 0 { table.insertRows(at: IndexSet(integersIn: 0..<inserted), withAnimation: []) }
            table.endUpdates()
            let newHead = inserted > 0 ? table.rect(ofRow: inserted - 1).maxY : 0
            scrollTo(y: before + newHead - oldHead)
            var changed = IndexSet()
            for index in 0..<(old.count - removed) where new[inserted + index] != old[removed + index] {
                changed.insert(inserted + index)
            }
            reconfigure(changed)
        case .reload:
            lines = new
            table.reloadData()
        }
    }

    /// A row's content reported its own height (it grew or shrank by itself: a tool group opened, a form folded).
    fileprivate func cellReported(_ cell: ThreadListCell, height reported: CGFloat) {
        let row = table.row(for: cell)
        guard row >= 0, lines.indices.contains(row), table.bounds.width > 0 else { return }
        let id = lines[row].id
        let clamped = ThreadListCell.clamp(reported)
        guard abs((heights[id] ?? -1) - clamped) > 0.5 else { return }
        let before = height(ofRow: row)
        heights[id] = clamped
        guard abs(before - clamped) > 0.5 else { return }
        pendingHeights.insert(row)
        scheduleHeights()
    }

    /// Gives the visible rows of `indexes` their new content; the others are made when they come into view. A row that
    /// turns from a native one into a SwiftUI one (or back) gets the other kind of cell.
    private func reconfigure(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        var remake = IndexSet()
        for index in indexes {
            let line = lines[index]
            guesses[line.id] = nil
            let shown = table.view(atColumn: 0, row: index, makeIfNecessary: false)
            let native = NativeRow.of(line)
            if let cell = shown as? NativeRowCell, let native, let context {
                cell.show(native, context: context)
                measure(cell, line: line, row: index)
                placeBars()
            } else if let cell = shown as? ThreadListCell, native == nil {
                configure(cell, with: line)
                measure(cell, line: line, row: index)
            } else if shown != nil {
                heights[line.id] = nil
                remake.insert(index)
            } else {
                heights[line.id] = nil
            }
        }
        if !remake.isEmpty { table.reloadData(forRowIndexes: remake, columnIndexes: IndexSet(integer: 0)) }
    }

    private func configure(_ cell: ThreadListCell, with line: ThreadListLine) {
        guard let context else { return }
        cell.show(line, context: context)
    }

    /// The height a row has at the table's width, as its content says; told to the table when it is not the one in use.
    private func measure(_ cell: any ThreadListRowCell, line: ThreadListLine, row: Int) {
        let width = table.bounds.width
        guard width > 0 else { return }
        let measured = cell.height(forWidth: width)
        let before = height(ofRow: row)
        heights[line.id] = measured
        guard abs(measured - before) > 0.5 else { return }
        pendingHeights.insert(row)
        scheduleHeights()
    }

    private func scheduleHeights() {
        guard !heightsScheduled else { return }
        heightsScheduled = true
        DispatchQueue.main.async { [weak self] in self?.applyHeights() }
    }

    /// Tells the table the rows' new heights. Rows above the screen that changed height move what is on screen: the
    /// scroll offset is moved by as much, so nothing seems to move.
    private func applyHeights() {
        heightsScheduled = false
        let rows = pendingHeights.filter { $0 < lines.count }
        pendingHeights = IndexSet()
        guard !rows.isEmpty else { return }
        let top = contentView.bounds.origin.y
        let firstVisible = table.rows(in: contentView.bounds).location
        var shift: CGFloat = 0
        if firstVisible != NSNotFound, firstVisible >= 0 {
            for row in rows where row < firstVisible {
                shift += table.rect(ofRow: row).height
            }
        }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.noteHeightOfRows(withIndexesChanged: IndexSet(rows))
        NSAnimationContext.endGrouping()
        if shift != 0, firstVisible != NSNotFound {
            var after: CGFloat = 0
            for row in rows where row < firstVisible { after += table.rect(ofRow: row).height }
            if abs(after - shift) > 0.5 { scrollTo(y: top + after - shift) }
        }
        reportMetrics()
        placeBars()
    }

    private func height(ofRow row: Int) -> CGFloat {
        guard lines.indices.contains(row) else { return 1 }
        let line = lines[row]
        if let known = heights[line.id] { return known }
        if let guess = guesses[line.id] { return guess }
        let guess: CGFloat =
            switch line {
            case .row(let key, _): ThreadHeightGuess.height(of: key.row) + Self.rowSpacing
            case .typing: 44 + Self.rowSpacing
            }
        guesses[line.id] = guess
        return guess
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { max(1, height(ofRow: row)) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard lines.indices.contains(row) else { return nil }
        let line = lines[row]
        if let native = NativeRow.of(line), let context {
            let cell = (tableView.makeView(withIdentifier: NativeRowCell.identifier, owner: nil) as? NativeRowCell)
                ?? NativeRowCell()
            if cell === hovered { hideHover(now: true) }
            cell.list = self
            cell.show(native, context: context)
            if heights[line.id] == nil { measure(cell, line: line, row: row) }
            DispatchQueue.main.async { [weak self] in self?.placeBars() }
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: ThreadListCell.identifier, owner: nil) as? ThreadListCell)
            ?? ThreadListCell()
        cell.list = self
        configure(cell, with: line)
        if heights[line.id] == nil { measure(cell, line: line, row: row) }
        return cell
    }

    /// A native row asks to be made again (a folded group was opened: it becomes the SwiftUI card).
    func reload(_ cell: NSView) {
        let row = table.row(for: cell)
        guard row >= 0, lines.indices.contains(row) else { return }
        heights[lines[row].id] = nil
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: actions under native messages

    private let hoverBar = NativeActionsHost(full: true)
    private let faintBar = NativeActionsHost(full: false)
    private weak var hovered: NativeRowCell?
    private var hideWork: DispatchWorkItem?

    /// The pointer came onto a native message, or left it: its bar of actions shows, and goes a moment after the pointer
    /// left (so that it can be reached across the gap), unless the pointer is on the bar or a popover of it is open.
    func nativeHover(_ cell: NativeRowCell, inside: Bool) {
        if inside {
            hideWork?.cancel()
            guard let spec = cell.messageSpec, !spec.streaming else { return }
            if hovered !== cell || hoverBar.model.spec != spec {
                hovered = cell
                hoverBar.model.reactOpen = false
                hoverBar.model.copied = false
                hoverBar.model.spec = spec
                hoverBar.model.context = context
                hoverBar.model.onSelectText = { [weak cell] in cell?.selectText() }
            }
            hoverBar.isHidden = false
            placeBars()
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if hoverBar.model.hovering || hoverBar.model.reactOpen {
                scheduleHide()
                return
            }
            hideHover(now: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func hideHover(now: Bool) {
        hideWork?.cancel()
        hovered = nil
        hoverBar.isHidden = true
        hoverBar.model.spec = nil
        placeBars()
    }

    /// Puts the bars under their messages: the hovered one, and the faint one under the agent's last message (hidden
    /// while that message is the hovered one).
    func placeBars() {
        if hoverBar.superview !== table {
            table.addSubview(hoverBar)
            table.addSubview(faintBar)
        }
        if let hovered, let bubble = hovered.bubbleFrame, let spec = hovered.messageSpec, hovered.superview != nil {
            hoverBar.place(under: table.convert(bubble, from: hovered), fromUser: spec.fromUser)
        } else if !hoverBar.isHidden {
            hoverBar.isHidden = true
        }
        let visible = table.rows(in: contentView.bounds)
        var last: NativeRowCell?
        if visible.location != NSNotFound {
            for row in visible.location..<min(lines.count, visible.location + visible.length) {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeRowCell,
                    cell.messageSpec?.isLastAgent == true
                {
                    last = cell
                }
            }
        }
        if let last, last !== hovered, let bubble = last.bubbleFrame, let spec = last.messageSpec {
            if faintBar.model.spec != spec {
                faintBar.model.spec = spec
                faintBar.model.context = context
                faintBar.model.onSelectText = { [weak last] in last?.selectText() }
            }
            faintBar.isHidden = false
            faintBar.place(under: table.convert(bubble, from: last), fromUser: false)
        } else if !faintBar.isHidden {
            faintBar.isHidden = true
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ThreadListRowView()
        // VoiceOver reads a row by what it says; its controls stay inside it.
        if lines.indices.contains(row) { view.setAccessibilityLabel(lines[row].accessibilityText) }
        return view
    }

    // MARK: width

    override func tile() {
        super.tile()
        defer { runPendingScroll() }
        let width = contentView.bounds.width
        if let column = table.tableColumns.first, abs(column.width - width) > 0.5 { column.width = width }
        if abs(width - measuredWidth) > 0.5 {
            // Another width makes every height wrong. The rows on screen are measured at once at the new width (they
            // must not stand at a guess); the others again as they are drawn.
            measuredWidth = width
            var kept: [String: CGFloat] = [:]
            if width > 0 {
                let visible = table.rows(in: contentView.bounds)
                if visible.location != NSNotFound {
                    for row in visible.location..<min(lines.count, visible.location + visible.length) {
                        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? any ThreadListRowCell
                        else { continue }
                        kept[lines[row].id] = cell.height(forWidth: width)
                    }
                }
            }
            heights = kept
            NativeSizeCache.shared.prefetch(lines, width: width)
            if !lines.isEmpty {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
                NSAnimationContext.endGrouping()
            }
        }
    }

    // MARK: scrolling

    private func scrollTo(y: CGFloat, slide: ThreadSlide? = nil) {
        let minY = -contentInsets.top
        let maxY = max(minY, table.frame.height + contentInsets.bottom - contentView.bounds.height)
        let target = NSPoint(x: 0, y: min(max(minY, y), maxY))
        if let slide, slide.curve.count == 4 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = slide.duration
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: slide.curve[0], slide.curve[1], slide.curve[2], slide.curve[3])
                context.allowsImplicitAnimation = true
                contentView.animator().setBoundsOrigin(target)
                reflectScrolledClipView(contentView)
            }
        } else {
            contentView.scroll(to: target)
            reflectScrolledClipView(contentView)
        }
    }

    /// Whether the list can be scrolled now: it is in a window and has a height.
    private var canScroll: Bool { window != nil && contentView.bounds.height > 0 }

    private func runPendingScroll() {
        guard canScroll, let pending = pendingScroll else { return }
        pendingScroll = nil
        // After this layout pass: the table has its rows and their heights then.
        DispatchQueue.main.async { pending() }
    }

    func scrollToBottom(slide: ThreadSlide?) {
        guard canScroll else {
            pendingScroll = { [weak self] in self?.scrollToBottom(slide: nil) }
            return
        }
        scrollTo(y: .greatestFiniteMagnitude, slide: slide)
    }

    func scroll(to id: String, centered: Bool, slide: ThreadSlide?) {
        guard canScroll else {
            pendingScroll = { [weak self] in self?.scroll(to: id, centered: centered, slide: nil) }
            return
        }
        guard let row = lines.firstIndex(where: { $0.id == id }) else { return }
        // The row is made and measured first, so the place is exact.
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        let y = centered ? rect.midY - contentView.bounds.height / 2 : rect.minY - Self.topInset / 2
        scrollTo(y: y, slide: slide)
    }

    func topRowID() -> String? {
        let visible = contentView.bounds
        let range = table.rows(in: visible)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        for row in range.location..<(range.location + range.length) {
            let rect = table.rect(ofRow: row)
            if rect.maxY > visible.minY + 1, case .row = lines[row] { return lines[row].id }
        }
        return nil
    }

    var metrics: ThreadScrollMetrics {
        let offset = contentView.bounds.origin.y + contentInsets.top
        let content = table.frame.height + contentInsets.top + contentInsets.bottom
        return ThreadScrollMetrics(offset: offset, contentHeight: content, height: contentView.bounds.height)
    }

    @objc private func boundsChanged() {
        ThreadScrollActivity.noteMove()
        reportMetrics()
    }

    private func reportMetrics() {
        let now = metrics
        guard now != lastMetrics else { return }
        lastMetrics = now
        controller?.onMetrics?(now)
        let near = ThreadScroll.nearTop(offset: Double(now.offset))
        if near != nearTop {
            nearTop = near
            if near { controller?.onNearTop?() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            reportMetrics()
            runPendingScroll()
        }
    }
}

/// The table: no selection, no keyboard focus of its own (the rows' controls take it), no type-select.
final class ThreadTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }

    /// Until then the table makes only the rows that show: a thread just opened (an agent switch) makes its first
    /// screen in the frame of the switch; the rows above and below it (AppKit's overdraw) come with the first scroll.
    private var visibleOnlyUntil: CFTimeInterval = 0

    func prepareOnlyVisible() {
        visibleOnlyUntil = CACurrentMediaTime() + 0.25
    }

    override func prepareContent(in rect: NSRect) {
        if CACurrentMediaTime() < visibleOnlyUntil {
            let visible = visibleRect
            super.prepareContent(in: visible.isEmpty ? rect : visible)
        } else {
            super.prepareContent(in: rect)
        }
    }
}

/// A row view that draws nothing: the rows draw their own look.
final class ThreadListRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A cell of the list: it tells its height for a width.
@MainActor
protocol ThreadListRowCell: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

extension ThreadListCell: ThreadListRowCell {}
extension NativeRowCell: ThreadListRowCell {}

/// A cell: one hosting controller, given each row it shows in turn.
final class ThreadListCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("thread-row")
    private let host = NSHostingController(rootView: ThreadListLineView(line: nil, context: nil, onHeight: nil))
    private var shown: ThreadListLine?
    /// The list that shows the cell: told when the content changes its height by itself.
    weak var list: ThreadListView?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        host.sizingOptions = []
        // A row has no safe area: without this, each row that scrolled under the title bar was given new insets and laid
        // out again at every step of a scroll.
        host.safeAreaRegions = []
        let view = host.view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ line: ThreadListLine, context: ThreadListContext) {
        // An equal line keeps its views: no new rootView, nothing is built.
        if shown == line { return }
        shown = line
        host.rootView = ThreadListLineView(
            line: line, context: context,
            onHeight: { [weak self] height in
                guard let self else { return }
                self.list?.cellReported(self, height: height)
            })
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        Self.clamp(host.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height)
    }

    /// A row is never taller than a screen can scroll through, and never not a number.
    static func clamp(_ height: CGFloat) -> CGFloat {
        height.isFinite ? min(max(height, 1), 100_000) : 100
    }
}

/// The lines last made for the list, and what they were made from. A stream changes the last row only: the other lines
/// are kept, not made again for every row at every token (each key looks up the row's reactions, quote and mentions).
@MainActor
final class ThreadListMemo {
    /// What the keys of all rows depend on besides the row.
    struct Signature: Equatable {
        var reactionsOn, repliesOn, formsOn, connectOn: Bool
        var accent: Color
        var reactions: [Int64: MessageReactions]
        var replies: [Int64: Int64]
        var mentions: [Int64: [Mention]]
        var viaButton: Set<Int64>
        var waiting: Set<Int64>
        var undelivered: Set<Int64>
        var highlightedID: String?
        var lastAgentID: String?
        var agentName, runtime, agentID: String
        var folder: String?
        var baseline: Int64?

        init(chat: ThreadChat, agentName: String, runtime: String, agentID: String, folder: String?, baseline: Int64?) {
            reactionsOn = chat.reactionsOn
            repliesOn = chat.repliesOn
            formsOn = chat.formsOn
            connectOn = chat.connectOn
            accent = chat.accent
            reactions = chat.reactions
            replies = chat.replies
            mentions = chat.mentions
            viaButton = chat.viaButton
            waiting = chat.waiting
            undelivered = chat.undelivered
            highlightedID = chat.highlightedID
            lastAgentID = chat.lastAgentID
            self.agentName = agentName
            self.runtime = runtime
            self.agentID = agentID
            self.folder = folder
            self.baseline = baseline
        }
    }

    private var signature: Signature?
    private var made: [ThreadListLine] = []
    private var typing: ThreadListLine?
    /// The version of the rows the lines were made from (`ThreadRowsMemo.version`).
    private var rowsVersion: Int?
    /// The lines handed to the list, with a version that changes with them.
    let box = ThreadListLines()

    /// The lines of `rows` (and the typing line under them): the kept ones when nothing changed, the kept ones with a
    /// new last line when only the last row changed since they were made (`memo` says so), else all made again with
    /// `make`. Returns the version of the lines.
    func update(
        rows: [ThreadRow], memo: ThreadRowsMemo, signature next: Signature, typing nextTyping: ThreadListLine?,
        make: (ThreadRow) -> ThreadListLine
    ) -> Int {
        var kind: ThreadRowsChange = .all
        if next == signature, made.count == rows.count, let rowsVersion {
            if rowsVersion == memo.version {
                kind = .none
            } else if memo.lastOnlyFrom == rowsVersion, let last = rows.last {
                made[made.count - 1] = make(last)
                kind = .last
            }
        }
        rowsVersion = memo.version
        if kind == .all {
            signature = next
            made = rows.map(make)
        }
        if nextTyping != typing {
            typing = nextTyping
            kind = .all
        }
        guard kind != .none else { return box.version }
        box.lines = nextTyping.map { made + [$0] } ?? made
        // With the typing line under the rows, the stream's row is not the last line: the list compares then.
        box.change = kind == .last && nextTyping == nil ? .last : .all
        box.version = ThreadListLines.nextVersion()
        return box.version
    }
}

/// The lines of a list, kept in a reference: SwiftUI compares the version, not thousands of lines, at every update.
@MainActor
final class ThreadListLines {
    var lines: [ThreadListLine] = []
    /// What changed with the last version: only the last line (a stream), or anything.
    var change = ThreadRowsChange.all
    /// Unique among all boxes, so a list given another box never takes its first version for the one it has.
    var version = ThreadListLines.nextVersion()

    private static var counter = 0
    static func nextVersion() -> Int {
        counter &+= 1
        return counter
    }
}

/// The SwiftUI content of a cell: the row at the width of the thread's column, with the space under it.
struct ThreadListLineView: View {
    var line: ThreadListLine?
    var context: ThreadListContext?
    /// The row's own height, reported when it changes (an opened tool group, a folded form): the cell is sized from it.
    var onHeight: ((CGFloat) -> Void)?

    var body: some View {
        Group {
            switch line {
            case .row(let key, let live)?:
                if let context {
                    EquatableThreadRow(key: key, server: context.server, chat: context.chat, onError: context.onError)
                        .equatable()
                        .modifier(LiveArrivalModifier(live: live))
                        .id(key.row.id)
                }
            case .typing(let activity, let since)?:
                TypingIndicator(activity: activity, since: since)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: 740, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, ThreadListView.rowSpacing)
        .frame(maxWidth: .infinity, alignment: .top)
        // The row is laid out for the width alone, the same way it is measured: the cell's height is then not a new
        // proposal, and the layout made for the measure is the one drawn.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { ($0.size.height * 2).rounded() / 2 } action: { height in
            onHeight?(height)
        }
        .modifier(SteadyWindowState())
    }
}

/// Keeps a row the same whether its window is in front or not. Each cell hosts its own SwiftUI view, and the window
/// going to the back (a sheet, another app) changed the environment of every cell: all the rows on screen were built
/// again, twice per sheet.
private struct SteadyWindowState: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .environment(\.controlActiveState, .key)
                .environment(\.appearsActive, true)
        } else {
            content.environment(\.controlActiveState, .key)
        }
    }
}

/// The rows of a thread in one stack, made as the list makes them: for snapshots and tests, which draw a thread
/// without a window.
struct ThreadItemsView: View {
    var items: [ThreadItem]
    var server: ServerModel
    var agentID = ""
    var folder: String?
    var onError: (UserFacingMessage) -> Void = { _ in }
    var agentName = ""
    var primaryRuntime = ""
    var chat = ThreadChat()
    /// Shows the typing indicator after the last row while a turn runs.
    var typing = false
    var turnStartedAt: Int64?

    var body: some View {
        var rowChat = chat
        rowChat.lastAgentID = ThreadListLine.lastAgentID(in: items)
        let context = ThreadListContext(server: server, agentID: agentID, chat: rowChat, onError: onError)
        var lines: [ThreadListLine] = ThreadRows.build(items).map { row in
            .row(
                ThreadRowKey(
                    row: row, agentName: agentName, primaryRuntime: primaryRuntime, agentID: agentID, folder: folder,
                    chat: rowChat),
                live: false)
        }
        if typing { lines.append(.typing(AgentActivity.current(in: items), since: turnStartedAt)) }
        return VStack(spacing: 0) {
            ForEach(lines) { line in ThreadListLineView(line: line, context: context) }
        }
        .padding(.top, ThreadListView.topInset)
        .padding(.bottom, ThreadListView.bottomInset)
    }
}
#endif
