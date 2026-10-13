import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

// The chat's text, laid out off the main thread. A row is measured once per (id, version, width, size category) and the
// result is kept: scrolling reads it, a stream measures only its own row. The results are plain values (strings and
// frames); the cells only place them.

extension NSAttributedString.Key {
    /// The web address under a piece of text. Not `.link`: drawing a string with `.link` paints it in the system's blue,
    /// and the chat sets the link's color itself.
    static let chatLink = NSAttributedString.Key("dev.bandito.chat.link")
}

/// The sizes of the chat's list, from its width. Points.
struct ChatMetrics: Equatable, Sendable {
    let width: CGFloat
    let category: UIContentSizeCategory

    /// The space left and right of every row.
    var side: CGFloat { 12 }
    /// The text's padding inside a bubble.
    var padX: CGFloat { 14 }
    var padY: CGFloat { 10 }
    var agentMax: CGFloat { max(160, width - side * 2 - 18) }
    var mineMax: CGFloat { max(160, (width - side * 2) * 0.88) }
    /// The widest a line of centred text may be.
    var lineMax: CGFloat { max(120, width - 48) }
    var pictureSide: CGFloat { 112 }
    var pictureGap: CGFloat { 6 }
}

/// The chat's fonts at one size category (a layout is measured for one).
struct ChatFonts: @unchecked Sendable {
    let body: UIFont
    let bold: UIFont
    let mono: UIFont
    let code: UIFont
    let heading: [UIFont]
    let caption: UIFont
    let line: UIFont
    let lineMono: UIFont
    let card: UIFont
    let cardStrong: UIFont

    init(category: UIContentSizeCategory) {
        body = BanditoFont.uiText(size: 15.5, weight: 400, category: category)
        bold = BanditoFont.uiText(size: 15.5, weight: 650, category: category)
        mono = BanditoFont.uiMono(size: 13.5, weight: 450, category: category)
        code = BanditoFont.uiMono(size: 12.5, weight: 400, category: category)
        heading = [
            BanditoFont.uiText(size: 21, weight: 700, category: category),
            BanditoFont.uiText(size: 18.5, weight: 700, category: category),
            BanditoFont.uiText(size: 17, weight: 650, category: category),
            BanditoFont.uiText(size: 15.5, weight: 650, category: category),
        ]
        caption = BanditoFont.uiText(size: 11.5, weight: 400, category: category)
        line = BanditoFont.uiText(size: 12.5, weight: 450, category: category)
        lineMono = BanditoFont.uiMono(size: 12, weight: 400, category: category)
        card = BanditoFont.uiText(size: 14.5, weight: 450, category: category)
        cardStrong = BanditoFont.uiDisplay(size: 14, weight: 600, category: category)
    }
}

/// A line or a block of text with the frame it is drawn in (in the cell's coordinates).
struct ChatTextItem: @unchecked Sendable {
    var string: NSAttributedString
    var frame: CGRect
}

/// A fenced code block: its header, and the code, which scrolls sideways when a line is wider than the block.
struct ChatCodeItem: @unchecked Sendable {
    var language: String?
    /// All of the code, for the Copy button.
    var code: String
    var frame: CGRect
    var header: CGFloat
    var display: NSAttributedString
    var contentSize: CGSize
    var scrolls: Bool
}

/// A file of a message: a picture tile or a chip with the name.
struct ChatFileItem: Sendable {
    var file: AgentAttachment
    var isPicture: Bool
    var frame: CGRect
}

/// What a message cell places.
struct ChatMessageLayout: @unchecked Sendable {
    enum Block: @unchecked Sendable {
        case text(ChatTextItem)
        case code(ChatCodeItem)
        case rule(CGRect)
        /// The bar left of a quote.
        case bar(CGRect)
    }

    var isMine: Bool
    var tail: Bool
    var bubble: CGRect?
    var blocks: [Block]
    var sender: ChatTextItem?
    var files: [ChatFileItem]
    var meta: ChatTextItem?
    /// What VoiceOver reads.
    var spoken: String
    /// The plain text, for Copy.
    var plain: String
}

struct ChatLineLayout: @unchecked Sendable {
    var symbol: CGRect?
    var text: ChatTextItem
    var chevron: CGRect?
    var detailBox: CGRect?
    var detail: ChatTextItem?
}

struct ChatToolsLayout: @unchecked Sendable {
    var header: CGRect
    var title: ChatTextItem
    var icon: CGRect
    var chevron: CGRect
    var rows: [(text: ChatTextItem, summary: ChatTextItem?)]
    var box: CGRect
}

struct ChatCardLayout: @unchecked Sendable {
    var card: CGRect
    var title: ChatTextItem
    var stats: ChatTextItem
    var icon: CGRect
    var chevron: CGRect
}

struct ChatWorkingLayout: @unchecked Sendable {
    var dots: CGRect
    var title: ChatTextItem
    var elapsed: CGRect
}

/// The measured row: its height and what its cell places.
final class ChatRowLayout: @unchecked Sendable {
    enum Payload: @unchecked Sendable {
        case message(ChatMessageLayout)
        case line(ChatLineLayout)
        case day(ChatTextItem)
        case tools(ChatToolsLayout)
        case card(ChatCardLayout)
        case working(ChatWorkingLayout)
        case hosted
    }

    let height: CGFloat
    let payload: Payload

    init(height: CGFloat, payload: Payload) {
        self.height = height
        self.payload = payload
    }
}

/// Measures rows. Thread safe; the cache is bounded.
final class ChatLayoutEngine: @unchecked Sendable {
    struct Key: Hashable {
        let id: String
        let version: Int
        let width: Int
        let category: String
    }

    static let shared = ChatLayoutEngine()

    private let lock = NSLock()
    private var cache: [Key: ChatRowLayout] = [:]
    private var order: [Key] = []
    private let limit = 4000
    private var fontCache: [String: ChatFonts] = [:]

    init() {}

    func fonts(_ category: UIContentSizeCategory) -> ChatFonts {
        lock.lock()
        defer { lock.unlock() }
        if let hit = fontCache[category.rawValue] { return hit }
        let made = ChatFonts(category: category)
        fontCache[category.rawValue] = made
        return made
    }

    func key(_ row: ChatRow, _ metrics: ChatMetrics) -> Key {
        Key(id: row.id, version: row.version, width: Int(metrics.width.rounded()), category: metrics.category.rawValue)
    }

    func cached(_ row: ChatRow, _ metrics: ChatMetrics) -> ChatRowLayout? {
        let key = key(row, metrics)
        return lock.withLock { cache[key] }
    }

    /// The layout of a row: kept, or measured now (on the caller's thread) and kept.
    func layout(_ row: ChatRow, _ metrics: ChatMetrics) -> ChatRowLayout {
        let key = key(row, metrics)
        if let hit = lock.withLock({ cache[key] }) { return hit }
        ChatCounters.shared.rowMeasured(row.id)
        let made = measure(row, metrics: metrics, fonts: fonts(metrics.category))
        lock.withLock {
            if cache.updateValue(made, forKey: key) == nil {
                order.append(key)
                if order.count > limit {
                    let drop = order.prefix(order.count - limit * 3 / 4)
                    for old in drop { cache.removeValue(forKey: old) }
                    order.removeFirst(drop.count)
                }
            }
        }
        return made
    }

    /// Measures the rows that are not kept yet, off the main thread, in four parts at once.
    func prefetch(_ rows: [ChatRow], _ metrics: ChatMetrics) async {
        let missing = rows.filter { !$0.content.isHosted && cached($0, metrics) == nil }
        guard !missing.isEmpty else { return }
        if missing.count < 4 {
            await Task.detached(priority: .userInitiated) { [self] in
                for row in missing { _ = layout(row, metrics) }
            }.value
            return
        }
        let parts = 4
        await withTaskGroup(of: Void.self) { group in
            for part in 0..<parts {
                group.addTask(priority: .userInitiated) { [self] in
                    var index = part
                    while index < missing.count {
                        _ = layout(missing[index], metrics)
                        index += parts
                    }
                }
            }
        }
    }

    func clear() {
        lock.withLock {
            cache = [:]
            order = []
        }
    }

    // MARK: measuring

    private func measure(_ row: ChatRow, metrics: ChatMetrics, fonts: ChatFonts) -> ChatRowLayout {
        switch row.content {
        case .message(let message):
            return Self.message(message, metrics: metrics, fonts: fonts)
        case .day(let text):
            return Self.centered(text, metrics: metrics, font: fonts.line, color: UIColor.Bandito.text3, minHeight: 24)
        case .chapter(let text, let warning):
            return Self.chapter(text, warning: warning, metrics: metrics, fonts: fonts)
        case .line(let line):
            return Self.line(line, metrics: metrics, fonts: fonts)
        case .tools(let group):
            return Self.tools(group, metrics: metrics, fonts: fonts)
        case .changes(let summary):
            return Self.changes(summary, metrics: metrics, fonts: fonts)
        case .working(let working):
            return Self.working(working, metrics: metrics, fonts: fonts)
        case .approval, .form, .connect:
            return ChatRowLayout(height: 0, payload: .hosted)
        }
    }

    static func size(of string: NSAttributedString, width: CGFloat) -> CGSize {
        let rect = string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

// MARK: - rows other than messages

extension ChatLayoutEngine {
    static func centered(_ text: String, metrics: ChatMetrics, font: UIFont, color: UIColor, minHeight: CGFloat) -> ChatRowLayout {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let string = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let size = Self.size(of: string, width: metrics.lineMax)
        let height = max(minHeight, size.height + 6)
        let frame = CGRect(x: (metrics.width - metrics.lineMax) / 2, y: (height - size.height) / 2, width: metrics.lineMax, height: size.height)
        return ChatRowLayout(height: height, payload: .day(ChatTextItem(string: string, frame: frame)))
    }

    static func chapter(_ text: String, warning: Bool, metrics: ChatMetrics, fonts: ChatFonts) -> ChatRowLayout {
        let color = warning ? UIColor(AvatarTile.peach) : UIColor.Bandito.text3
        return centered(text, metrics: metrics, font: fonts.line, color: color, minHeight: 28)
    }

    static func line(_ line: ChatLine, metrics: ChatMetrics, fonts: ChatFonts) -> ChatRowLayout {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let color: UIColor =
            switch line.tone {
            case .note: UIColor.Bandito.text3
            case .muted: UIColor.Bandito.text3.withAlphaComponent(0.75)
            case .error: UIColor.Bandito.danger
            case .warning: UIColor(AvatarTile.peach)
            }
        let string = NSAttributedString(
            string: line.text, attributes: [.font: fonts.line, .foregroundColor: color, .paragraphStyle: style])
        let symbolWidth: CGFloat = line.symbol == nil ? 0 : 18
        let chevronWidth: CGFloat = line.fold == nil ? 0 : 16
        let textWidth = metrics.lineMax - symbolWidth - chevronWidth
        let measured = Self.size(of: string, width: textWidth)
        let rowHeight = max(28, measured.height + 8)
        let total = symbolWidth + measured.width + chevronWidth
        var x = (metrics.width - total) / 2
        var symbol: CGRect?
        if symbolWidth > 0 {
            symbol = CGRect(x: x, y: (rowHeight - 14) / 2, width: 14, height: 14)
            x += symbolWidth
        }
        let text = ChatTextItem(string: string, frame: CGRect(x: x, y: (rowHeight - measured.height) / 2, width: measured.width, height: measured.height))
        x += measured.width
        var chevron: CGRect?
        if chevronWidth > 0 {
            chevron = CGRect(x: x + 4, y: (rowHeight - 10) / 2, width: 10, height: 10)
        }
        var layout = ChatLineLayout(symbol: symbol, text: text, chevron: chevron, detailBox: nil, detail: nil)
        var height = rowHeight
        if let fold = line.fold, fold.open {
            let detailStyle = NSMutableParagraphStyle()
            detailStyle.lineBreakMode = .byWordWrapping
            detailStyle.lineSpacing = 2
            let shown = String(fold.detail.prefix(4000))
            let detail = NSAttributedString(
                string: shown,
                attributes: [.font: fonts.lineMono, .foregroundColor: UIColor.Bandito.text2, .paragraphStyle: detailStyle])
            let boxWidth = metrics.width - metrics.side * 2
            let inner = boxWidth - 24
            let detailSize = Self.size(of: detail, width: inner)
            let box = CGRect(x: metrics.side, y: rowHeight + 2, width: boxWidth, height: detailSize.height + 20)
            layout.detailBox = box
            layout.detail = ChatTextItem(
                string: detail, frame: CGRect(x: box.minX + 12, y: box.minY + 10, width: inner, height: detailSize.height))
            height = box.maxY + 2
        }
        return ChatRowLayout(height: height, payload: .line(layout))
    }

    static func tools(_ group: ChatToolGroup, metrics: ChatMetrics, fonts: ChatFonts) -> ChatRowLayout {
        let boxWidth = metrics.width - metrics.side * 2
        let titleString = NSAttributedString(
            string: group.title,
            attributes: [.font: fonts.line, .foregroundColor: UIColor.Bandito.text2, .paragraphStyle: truncating()])
        let headerHeight: CGFloat = 36
        let titleSize = Self.size(of: titleString, width: boxWidth - 70)
        let header = CGRect(x: metrics.side, y: 0, width: boxWidth, height: headerHeight)
        let title = ChatTextItem(
            string: titleString,
            frame: CGRect(x: header.minX + 36, y: (headerHeight - titleSize.height) / 2, width: min(titleSize.width, boxWidth - 70), height: titleSize.height))
        let icon = CGRect(x: header.minX + 12, y: (headerHeight - 14) / 2, width: 14, height: 14)
        let chevron = CGRect(x: header.maxX - 26, y: (headerHeight - 10) / 2, width: 12, height: 10)
        var rows: [(text: ChatTextItem, summary: ChatTextItem?)] = []
        var bottom = headerHeight
        if group.open {
            bottom += 4
            for tool in group.tools.prefix(60) {
                let line = NSAttributedString(
                    string: "$ " + tool.title,
                    attributes: [.font: fonts.lineMono, .foregroundColor: UIColor.Bandito.text2, .paragraphStyle: truncating()])
                let height = ceil(fonts.lineMono.lineHeight)
                let text = ChatTextItem(
                    string: line, frame: CGRect(x: header.minX + 14, y: bottom, width: boxWidth - 28, height: height))
                var summary: ChatTextItem?
                if let ok = tool.ok {
                    let first = tool.output?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    let shown = first.isEmpty ? (ok ? "✓" : "✗") : String(first.prefix(80))
                    let attributed = NSAttributedString(
                        string: shown,
                        attributes: [
                            .font: fonts.lineMono, .foregroundColor: ok ? UIColor.Bandito.ok : UIColor.Bandito.danger,
                            .paragraphStyle: truncating(),
                        ])
                    summary = ChatTextItem(
                        string: attributed,
                        frame: CGRect(x: header.minX + 30, y: bottom + height, width: boxWidth - 44, height: height))
                }
                rows.append((text, summary))
                bottom += height + (summary == nil ? 0 : height) + 6
            }
            bottom += 6
        }
        let box = CGRect(x: metrics.side, y: 0, width: boxWidth, height: bottom)
        let layout = ChatToolsLayout(header: header, title: title, icon: icon, chevron: chevron, rows: rows, box: box)
        return ChatRowLayout(height: bottom, payload: .tools(layout))
    }

    static func truncating() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }

    static func changes(_ summary: ChatChangesSummary, metrics: ChatMetrics, fonts: ChatFonts) -> ChatRowLayout {
        let boxWidth = metrics.width - metrics.side * 2
        let height: CGFloat = 60
        let title = NSAttributedString(
            string: L10n.Changes.fileCount(count: summary.files),
            attributes: [.font: fonts.cardStrong, .foregroundColor: UIColor.Bandito.text, .paragraphStyle: truncating()])
        let stats = NSMutableAttributedString(
            string: ChangesChips.additions(summary.additions),
            attributes: [.font: fonts.lineMono, .foregroundColor: UIColor.Bandito.ok])
        stats.append(NSAttributedString(string: "  ", attributes: [.font: fonts.lineMono]))
        stats.append(
            NSAttributedString(
                string: ChangesChips.deletions(summary.deletions),
                attributes: [.font: fonts.lineMono, .foregroundColor: UIColor.Bandito.danger]))
        let titleSize = Self.size(of: title, width: boxWidth - 100)
        let statsSize = Self.size(of: stats, width: boxWidth - 100)
        let gap: CGFloat = 3
        let block = titleSize.height + gap + statsSize.height
        let top = (height - block) / 2
        let card = CGRect(x: metrics.side, y: 0, width: boxWidth, height: height)
        let layout = ChatCardLayout(
            card: card,
            title: ChatTextItem(string: title, frame: CGRect(x: card.minX + 56, y: top, width: boxWidth - 100, height: titleSize.height)),
            stats: ChatTextItem(string: stats, frame: CGRect(x: card.minX + 56, y: top + titleSize.height + gap, width: boxWidth - 100, height: statsSize.height)),
            icon: CGRect(x: card.minX + 16, y: (height - 24) / 2, width: 24, height: 24),
            chevron: CGRect(x: card.maxX - 28, y: (height - 12) / 2, width: 8, height: 12))
        return ChatRowLayout(height: height, payload: .card(layout))
    }

    static func working(_ working: ChatWorking, metrics: ChatMetrics, fonts: ChatFonts) -> ChatRowLayout {
        let title = NSAttributedString(
            string: working.title,
            attributes: [.font: fonts.line, .foregroundColor: UIColor.Bandito.text2, .paragraphStyle: truncating()])
        let titleSize = Self.size(of: title, width: metrics.width - 140)
        let height: CGFloat = 34
        let dots = CGRect(x: metrics.side + 6, y: (height - 8) / 2, width: 28, height: 8)
        let titleItem = ChatTextItem(
            string: title,
            frame: CGRect(x: dots.maxX + 8, y: (height - titleSize.height) / 2, width: min(titleSize.width, metrics.width - 140), height: titleSize.height))
        let elapsed = CGRect(x: titleItem.frame.maxX + 6, y: (height - 16) / 2, width: 70, height: 16)
        return ChatRowLayout(height: height, payload: .working(ChatWorkingLayout(dots: dots, title: titleItem, elapsed: elapsed)))
    }
}
