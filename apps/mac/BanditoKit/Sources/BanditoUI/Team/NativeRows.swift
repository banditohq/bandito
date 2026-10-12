#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

// The thread's most frequent rows drawn by AppKit: a message of the person or of the agent (running text and code
// blocks), a day's caption and a note. A SwiftUI row in its own hosting view cost 5–8 ms to make on a Mac without a
// GPU and still several on a fast one, so a scroll made the main thread late; these cost a text view's layout. They look
// as the SwiftUI rows do (same parsed text, fonts, colours, bubble shapes and spacing, see `NativeMessageGeometry`).
// The rest (forms, approvals, cards, messages with a quote, files, mentions, reactions or a web link) stay SwiftUI rows.

/// What a native row shows.
enum NativeRow: Equatable {
    case message(NativeMessageSpec)
    case day(caption: String)
    case note(text: String, isError: Bool)
    /// A folded group of finished tool calls: its key (`ThreadDisclosure`), title and whether one failed.
    case tools(key: String, title: String, failed: Bool)
    /// A folded scheduled run or quiet turn (`SystemLine`); open, it is the SwiftUI row.
    case systemLine(SystemLineSpec)

    /// The native row for a line, or nil when the line stays a SwiftUI row.
    @MainActor
    static func of(_ line: ThreadListLine) -> NativeRow? {
        guard case .row(let key, let live) = line, !live else { return nil }
        switch key.row {
        case .day(let date):
            return .day(caption: DayCaption.text(date))
        case .toolGroup(let tools):
            // A running group (its icon moves) or an opened one stays the SwiftUI card.
            let disclosure = "tools-\(tools.first?.callId ?? "")"
            guard !tools.contains(where: { $0.ok == nil }), !ThreadDisclosure.shared.isOpen(disclosure) else { return nil }
            return .tools(
                key: disclosure, title: ToolGroupTitle.text(oks: tools.map(\.ok)),
                failed: tools.contains { $0.ok == false })
        case .item(let item):
            switch item {
            case .scheduleRun, .quietTurn:
                guard let spec = ScheduleRunLine.spec(of: item), !ThreadDisclosure.shared.isOpen(spec.key) else { return nil }
                return .systemLine(spec)
            case .note(_, let text, let kind, _):
                return .note(text: text, isError: kind == .error)
            case .runtimeSwitch(_, let from, let to, let until, _):
                return .note(
                    text: RuntimeSwitchNote.text(from: from, to: to, until: until, primary: key.primaryRuntime),
                    isError: false)
            case .assistant(let id, let text, let ts):
                guard key.isPlain, !hasWebLink(text, markdown: true) else { return nil }
                return .message(
                    NativeMessageSpec(
                        id: id, seq: item.messageSeq, text: text, fromUser: false, streaming: false,
                        sentAt: Date(timeIntervalSince1970: TimeInterval(ts) / 1000), flashing: key.flashing,
                        isLastAgent: key.isLastAgent, reactionsOn: key.reactionsOn, repliesOn: key.repliesOn,
                        accent: key.accent))
            case .streaming(let text):
                guard !hasWebLink(text, markdown: true) else { return nil }
                return .message(
                    NativeMessageSpec(
                        id: item.id, seq: nil, text: text, fromUser: false, streaming: true, sentAt: nil,
                        flashing: false, isLastAgent: false, reactionsOn: false, repliesOn: false, accent: key.accent))
            case .user(let id, let text, let source, _, let ts, let files):
                guard source == .user, !text.isEmpty, files.isEmpty, key.isPlain,
                    !hasWebLink(text, markdown: false)
                else { return nil }
                return .message(
                    NativeMessageSpec(
                        id: id, seq: item.messageSeq, text: text, fromUser: true, streaming: false,
                        sentAt: Date(timeIntervalSince1970: TimeInterval(ts) / 1000), flashing: key.flashing,
                        isLastAgent: false, reactionsOn: key.reactionsOn, repliesOn: key.repliesOn, accent: key.accent))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// A message with a web link keeps the SwiftUI row: it has the hover hint of where the link opens.
    private static func hasWebLink(_ text: String, markdown: Bool) -> Bool {
        guard text.contains("http") else { return false }
        return MessageRenderCache.shared.message(for: text, markdown: markdown).firstWebLink != nil
    }
}

extension ThreadRowKey {
    /// Nothing beside the bubble: no quote, mentions, reactions, queued or button marks.
    var isPlain: Bool {
        quoted == nil && mentions.isEmpty && !viaButton && waiting == 0 && (reactions?.chips.isEmpty ?? true)
    }
}

/// The caption of a day: "Today", "Yesterday" or the date (as `DayDivider`).
enum DayCaption {
    static func text(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return L10n.Thread.today }
        if calendar.isDateInYesterday(date) { return L10n.Thread.yesterday }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

/// A message as a native row draws it.
struct NativeMessageSpec: Equatable {
    var id: String
    var seq: Int64?
    var text: String
    var fromUser: Bool
    /// Still being written: no actions, no space for them under the bubble.
    var streaming: Bool
    var sentAt: Date?
    var flashing: Bool
    var isLastAgent: Bool
    var reactionsOn: Bool
    var repliesOn: Bool
    var accent: Color
}

/// One block of a message's body in a native row.
enum NativeBlock {
    case text(NSAttributedString)
    case code(language: String?, code: String, text: NSAttributedString, scrolls: Bool)
}

/// Where everything of a native message goes in a cell of a given width. Pure, so it is tested against the numbers of
/// the SwiftUI row: the line is at most 740 pt wide and centred, with 24 pt at the sides; a bubble leaves at least
/// 120 pt free on the other side, has 14 × 10 pt of padding; blocks are 10 pt apart when there is code, else the two
/// texts of a stream are 4 (3) pt apart; a finished message keeps 16 pt for its actions under it; 12 pt between rows.
struct NativeMessageGeometry: Equatable {
    var bubble: CGRect
    /// The blocks, in the bubble's coordinates.
    var blocks: [CGRect]
    var height: CGFloat

    static let sideInset: CGFloat = 24
    static let maxLine: CGFloat = 740
    static let freeSide: CGFloat = 120
    static let padding = CGSize(width: 14, height: 10)
    /// A code block: the header row (6 pt above, 24 pt high), 4 pt to the code, the code, 12 pt below.
    static let codeChrome: CGFloat = 6 + 24 + 4 + 12
    static let codeInset: CGFloat = 12

    /// The width a text of the message may take in a cell of `width`.
    static func textWidth(cellWidth width: CGFloat) -> CGFloat {
        max(40, column(width).width - freeSide - padding.width * 2)
    }

    static func column(_ width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let inner = max(0, width - sideInset * 2)
        let column = min(inner, maxLine)
        return (sideInset + (inner - column) / 2, column)
    }

    /// - Parameters:
    ///   - sizes: each block's size: a text's own (widest line, height), a code block's code (height only counts).
    ///   - code: which blocks are code blocks.
    static func make(
        cellWidth width: CGFloat, fromUser: Bool, streaming: Bool, markdown: Bool, sizes: [CGSize], code: [Bool]
    ) -> NativeMessageGeometry {
        let (columnX, columnWidth) = column(width)
        let maxText = textWidth(cellWidth: width)
        let hasCode = code.contains(true)
        let spacing: CGFloat = hasCode ? 10 : NativeRowText.lineSpacing(markdown: markdown)
        var contentWidth: CGFloat = 0
        var frames: [CGRect] = []
        var y = padding.height
        for (index, size) in sizes.enumerated() {
            let isCode = index < code.count && code[index]
            let blockHeight = isCode ? size.height + codeChrome : size.height
            let blockWidth = isCode ? maxText : min(size.width, maxText)
            contentWidth = max(contentWidth, blockWidth)
            frames.append(CGRect(x: padding.width, y: y, width: blockWidth, height: blockHeight))
            y += blockHeight + spacing
        }
        if hasCode { contentWidth = maxText }
        // Code blocks fill the bubble's width; texts keep their own.
        frames = zip(frames, code + Array(repeating: false, count: max(0, frames.count - code.count))).map { frame, isCode in
            isCode ? CGRect(x: frame.minX, y: frame.minY, width: contentWidth, height: frame.height) : frame
        }
        let contentHeight = sizes.isEmpty ? 0 : y - spacing - padding.height
        let bubbleSize = CGSize(width: contentWidth + padding.width * 2, height: contentHeight + padding.height * 2)
        let bubbleX = fromUser ? columnX + columnWidth - bubbleSize.width : columnX
        let below = (streaming ? 0 : MessageActionsPlacement.reservedBelow) + ThreadListView.rowSpacing
        return NativeMessageGeometry(
            bubble: CGRect(origin: CGPoint(x: bubbleX, y: 0), size: bubbleSize), blocks: frames,
            height: bubbleSize.height + below)
    }
}

/// The blocks of a message, ready to lay out: parsed once (`MessageRenderCache`), turned into attributed strings.
enum NativeMessageBlocks {
    @MainActor
    static func make(_ spec: NativeMessageSpec) -> [NativeBlock] {
        make(spec, color: NSColor(Color.Bandito.text), peach: NSColor(BanditoPalette.peach))
    }

    /// Any thread: the colours do not change the sizes, so a measure off the main thread passes any.
    nonisolated static func make(_ spec: NativeMessageSpec, color: NSColor, peach: NSColor) -> [NativeBlock] {
        let markdown = !spec.fromUser
        let message =
            spec.streaming
            ? MessageRenderCache.shared.streamingMessage(for: spec.text, markdown: markdown)
            : MessageRenderCache.shared.message(for: spec.text, markdown: markdown)
        return message.blocks.map { block in
            switch block {
            case .text(let value):
                return .text(NativeRowText.running(value, markdown: markdown, color: color, peach: peach))
            case .code(let language, let code):
                return .code(
                    language: language, code: code, text: NativeRowText.code(code, color: color),
                    scrolls: CodeBlockLayout.needsScroll(code))
            }
        }
    }

    /// The sizes `NativeMessageGeometry` takes, for a cell of `width`.
    nonisolated static func sizes(_ blocks: [NativeBlock], cellWidth width: CGFloat) -> [CGSize] {
        let maxText = NativeMessageGeometry.textWidth(cellWidth: width)
        return blocks.map { block in
            switch block {
            case .text(let text):
                return NativeRowText.size(of: text, width: maxText)
            case .code(_, _, let text, let scrolls):
                let wrap = scrolls ? CGFloat.greatestFiniteMagnitude : maxText - NativeMessageGeometry.codeInset * 2
                return NativeRowText.size(of: text, width: wrap)
            }
        }
    }

    nonisolated static func isCode(_ blocks: [NativeBlock]) -> [Bool] {
        blocks.map { if case .code = $0 { true } else { false } }
    }
}

/// The measured blocks of finished messages, by message and width. A list measures the messages it holds off the main
/// thread (`prefetch`), the newest first, so a row that comes into view is laid out from here and the main thread
/// only draws it.
final class NativeSizeCache: @unchecked Sendable {
    static let shared = NativeSizeCache()

    struct Key: Hashable {
        var id: String
        var length: Int
        var hash: Int
        var fromUser: Bool
        var width: Int

        init(_ spec: NativeMessageSpec, width: CGFloat) {
            id = spec.id
            length = spec.text.utf8.count
            hash = spec.text.hashValue
            fromUser = spec.fromUser
            self.width = Int((width * 2).rounded())
        }
    }

    private let lock = NSLock()
    private var sizes: [Key: [CGSize]] = [:]
    private var order: [Key] = []
    private let limit = 6000

    func sizes(for key: Key) -> [CGSize]? { lock.withLock { sizes[key] } }

    func store(_ value: [CGSize], for key: Key) {
        lock.withLock {
            if sizes.updateValue(value, forKey: key) == nil { order.append(key) }
            if order.count > limit {
                for old in order.prefix(order.count - limit) { sizes[old] = nil }
                order.removeFirst(order.count - limit)
            }
        }
    }

    /// Measures the finished messages among `lines` for cells of `width`, on a background thread, the last first.
    func prefetch(_ lines: [ThreadListLine], width: CGFloat) {
        guard width > 0 else { return }
        let specs: [NativeMessageSpec] = lines.reversed().compactMap { line in
            guard case .row(let key, _) = line, case .item(let item) = key.row else { return nil }
            switch item {
            case .assistant(let id, let text, _):
                return NativeMessageSpec(
                    id: id, seq: nil, text: text, fromUser: false, streaming: false, sentAt: nil, flashing: false,
                    isLastAgent: false, reactionsOn: false, repliesOn: false, accent: .clear)
            case .user(let id, let text, let source, _, _, let files) where source == .user && files.isEmpty && !text.isEmpty:
                return NativeMessageSpec(
                    id: id, seq: nil, text: text, fromUser: true, streaming: false, sentAt: nil, flashing: false,
                    isLastAgent: false, reactionsOn: false, repliesOn: false, accent: .clear)
            default:
                return nil
            }
        }
        nonisolated(unsafe) let ink = NSColor.black
        Task.detached(priority: .utility) { [self] in
            for spec in specs {
                let key = Key(spec, width: width)
                if sizes(for: key) != nil { continue }
                let blocks = NativeMessageBlocks.make(spec, color: ink, peach: ink)
                store(NativeMessageBlocks.sizes(blocks, cellWidth: width), for: key)
            }
        }
    }
}
#endif
