import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

// A message measured: its Markdown read into blocks, each block turned into an attributed string and laid out at the
// width of the bubble. Runs on any thread.

extension ChatLayoutEngine {
    /// A paragraph of text with the space after it.
    private struct Paragraph {
        var string: NSMutableAttributedString
        var spaceAfter: CGFloat
    }

    /// Characters a run keeps in one view: a longer run is cut into several, so no view is taller than the GPU draws.
    private static let chunkCharacters = 2500
    /// The most characters of one paragraph that are drawn. Copy still has them all.
    private static let paragraphLimit = 12_000
    private static let codeLineLimit = 300

    static func message(_ message: ChatMessage, metrics: ChatMetrics, fonts: ChatFonts) -> ChatRowLayout {
        let isMine = message.isMine
        let maxBubble = isMine ? metrics.mineMax : metrics.agentMax
        let inner = maxBubble - metrics.padX * 2
        let blocks = ChatMarkdown.parse(message.text, markdown: message.markdown)

        // Blocks, in the bubble's own coordinates (the origin is the bubble's top left).
        var placed: [ChatMessageLayout.Block] = []
        var y = metrics.padY
        var widest: CGFloat = 0
        var run: [Paragraph] = []

        // The quote of a reply comes first, in a quiet plate; the plate is as wide as the bubble ends up (set below).
        var panelIndex: Int?
        if let reply = message.reply {
            let barWidth: CGFloat = 3
            let textX = metrics.padX + 10
            let textWidth = max(40, inner - 10 - 8)
            let name = NSAttributedString(
                string: reply.name,
                attributes: [.font: fonts.quoteName, .foregroundColor: UIColor.Bandito.text2, .paragraphStyle: truncating()])
            let nameHeight = ceil(fonts.quoteName.lineHeight)
            let words = reply.excerpt ?? L10n.Reply.earlier
            let wordsStyle = NSMutableParagraphStyle()
            wordsStyle.lineBreakMode = .byTruncatingTail
            let excerpt = NSAttributedString(
                string: words,
                attributes: [.font: fonts.quoteText, .foregroundColor: UIColor.Bandito.text3, .paragraphStyle: wordsStyle])
            let measured = Self.size(of: excerpt, width: textWidth)
            let twoLines = ceil(fonts.quoteText.lineHeight) * 2
            let wordsHeight = min(measured.height, twoLines)
            let top = y + 6
            let panelHeight = 6 + nameHeight + 2 + wordsHeight + 6
            panelIndex = placed.count
            placed.append(.panel(CGRect(x: metrics.padX, y: y, width: inner, height: panelHeight)))
            placed.append(.bar(CGRect(x: metrics.padX, y: y + 4, width: barWidth, height: panelHeight - 8)))
            let nameWidth = min(Self.size(of: name, width: textWidth).width, textWidth)
            placed.append(.text(ChatTextItem(string: name, frame: CGRect(x: textX, y: top, width: textWidth, height: nameHeight))))
            placed.append(
                .text(
                    ChatTextItem(
                        string: excerpt,
                        frame: CGRect(x: textX, y: top + nameHeight + 2, width: textWidth, height: wordsHeight))))
            widest = max(widest, 10 + 8 + max(nameWidth, min(measured.width, textWidth)))
            y += panelHeight
        }

        func gap() {
            if !placed.isEmpty { y += 8 }
        }
        func flushRun(quote: Bool = false) {
            guard !run.isEmpty else { return }
            run[run.count - 1].spaceAfter = 0
            let indent: CGFloat = quote ? 12 : 0
            let width = inner - indent
            gap()
            let startY = y
            for chunk in chunks(of: run) {
                let joined = NSMutableAttributedString()
                for (index, paragraph) in chunk.enumerated() {
                    let piece = NSMutableAttributedString(attributedString: paragraph.string)
                    if index < chunk.count - 1 {
                        piece.append(NSAttributedString(string: "\n", attributes: paragraph.string.attributes(at: 0, effectiveRange: nil)))
                    }
                    joined.append(piece)
                }
                let size = Self.size(of: joined, width: width)
                widest = max(widest, size.width + indent)
                placed.append(
                    .text(
                        ChatTextItem(
                            string: joined,
                            frame: CGRect(x: metrics.padX + indent, y: y, width: width, height: size.height))))
                y += size.height + (chunk.last?.spaceAfter ?? 0)
            }
            if quote {
                placed.append(.bar(CGRect(x: metrics.padX, y: startY, width: 3, height: y - startY)))
            }
            run = []
        }

        for block in blocks {
            switch block {
            case .paragraph(let text):
                run.append(paragraph(text, fonts: fonts, message: message))
            case .heading(let level, let text):
                run.append(heading(text, level: level, first: run.isEmpty && placed.isEmpty, fonts: fonts))
            case .listItem(let marker, let depth, let text):
                run.append(listItem(marker: marker, depth: depth, text: text, fonts: fonts))
            case .quote(let text):
                flushRun()
                run.append(quoteParagraph(text, fonts: fonts))
                flushRun(quote: true)
            case .rule:
                flushRun()
                gap()
                placed.append(.rule(CGRect(x: metrics.padX, y: y + 4, width: inner, height: 1)))
                y += 9
                widest = max(widest, inner)
            case .code(let language, let code, _):
                flushRun()
                gap()
                let item = codeBlock(language: language, code: code, width: inner, originY: y, x: metrics.padX, fonts: fonts)
                placed.append(.code(item))
                y += item.frame.height
                widest = inner
            }
        }
        flushRun()

        let hasBubble = !placed.isEmpty
        let bubbleWidth = hasBubble ? min(maxBubble, max(widest + metrics.padX * 2, 46)) : 0
        let bubbleHeight = hasBubble ? y + metrics.padY : 0
        if let panelIndex, case .panel(var rect) = placed[panelIndex] {
            rect.size.width = bubbleWidth - metrics.padX * 2
            placed[panelIndex] = .panel(rect)
            if case .bar(var bar) = placed[panelIndex + 1] { bar.size.width = 3; placed[panelIndex + 1] = .bar(bar) }
        }

        // The cell: sender line, files, bubble, caption.
        var cellY: CGFloat = 0
        var sender: ChatTextItem?
        if case .crew(let from) = message.sender, let from {
            let string = NSAttributedString(
                string: L10n.Thread.messageFrom(name: from),
                attributes: [.font: fonts.caption, .foregroundColor: UIColor.Bandito.text3, .paragraphStyle: truncating()])
            let size = Self.size(of: string, width: maxBubble)
            sender = ChatTextItem(
                string: string, frame: CGRect(x: metrics.side + 4, y: 0, width: min(size.width, maxBubble), height: size.height))
            cellY += size.height + 4
        }
        let files = layoutFiles(message.files, originY: &cellY, metrics: metrics, fonts: fonts, mine: isMine)
        let originX = isMine ? metrics.width - metrics.side - bubbleWidth : metrics.side
        var bubble: CGRect?
        if hasBubble {
            bubble = CGRect(x: originX, y: cellY, width: bubbleWidth, height: bubbleHeight)
            cellY += bubbleHeight
        }
        let shifted = placed.map { shift($0, dx: originX, dy: bubble?.minY ?? 0) }

        // The reactions, under the bubble on the speaker's side.
        let chips = layoutChips(message.reactions, originY: &cellY, metrics: metrics, fonts: fonts, mine: isMine)

        var quote: CGRect?
        for block in shifted { if case .panel(let rect) = block { quote = rect } }

        var meta: ChatTextItem?
        if let string = metaString(message, fonts: fonts) {
            let size = Self.size(of: string, width: maxBubble)
            let width = min(size.width, maxBubble)
            let x = isMine ? metrics.width - metrics.side - width - 4 : metrics.side + 4
            meta = ChatTextItem(string: string, frame: CGRect(x: x, y: cellY + 3, width: width, height: size.height))
            cellY += 3 + size.height
        }

        let plain = message.markdown ? MessageBlocks.plainText(message.text) : message.text
        let layout = ChatMessageLayout(
            isMine: isMine, tail: message.tail, bubble: bubble, blocks: shifted, sender: sender, files: files, meta: meta,
            spoken: spokenText(message, plain: plain), plain: plain, quote: quote, quoteSeq: message.reply?.seq, chips: chips)
        return ChatRowLayout(height: ceil(cellY), payload: .message(layout))
    }

    /// What VoiceOver reads: the quote it answers (when there is one), the words, and the reactions.
    private static func spokenText(_ message: ChatMessage, plain: String) -> String {
        var parts: [String] = []
        if let reply = message.reply {
            parts.append(L10n.Thread.reply + " " + reply.name + ": " + (reply.excerpt ?? L10n.Reply.earlier) + ".")
        }
        parts.append(plain)
        if !message.reactions.isEmpty {
            parts.append(message.reactions.map { $0.emoji }.joined(separator: " "))
        }
        return parts.joined(separator: " ")
    }

    /// The chips of a message's reactions: a row of capsules 24 high, the person's first, on the speaker's side. A row
    /// that does not fit the width goes on to the next line.
    private static func layoutChips(
        _ chips: [ChatReactionChip], originY: inout CGFloat, metrics: ChatMetrics, fonts: ChatFonts, mine: Bool
    ) -> [ChatChipItem] {
        guard !chips.isEmpty else { return [] }
        let height: CGFloat = 24
        let gap: CGFloat = 6
        let available = metrics.width - metrics.side * 2
        var widths: [CGFloat] = []
        for chip in chips {
            let emoji = NSAttributedString(string: chip.emoji, attributes: [.font: fonts.chip])
            let text = Self.size(of: emoji, width: 200).width
            widths.append(text + 18 + (chip.byUser && chip.byAgent ? 12 : 0))
        }
        var items: [ChatChipItem] = []
        var top = originY + 4
        var index = 0
        while index < chips.count {
            var end = index
            var rowWidth: CGFloat = 0
            while end < chips.count, rowWidth + widths[end] + (end > index ? gap : 0) <= available || end == index {
                rowWidth += widths[end] + (end > index ? gap : 0)
                end += 1
            }
            var x = mine ? metrics.width - metrics.side - rowWidth : metrics.side
            for position in index..<end {
                items.append(ChatChipItem(chip: chips[position], frame: CGRect(x: x, y: top, width: widths[position], height: height)))
                x += widths[position] + gap
            }
            top += height + 4
            index = end
        }
        originY = top - 4 + 0
        return items
    }

    private static func shift(_ block: ChatMessageLayout.Block, dx: CGFloat, dy: CGFloat) -> ChatMessageLayout.Block {
        func moved(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: dx, dy: dy) }
        switch block {
        case .text(var item):
            item.frame = moved(item.frame)
            return .text(item)
        case .code(var item):
            item.frame = moved(item.frame)
            return .code(item)
        case .rule(let rect): return .rule(moved(rect))
        case .bar(let rect): return .bar(moved(rect))
        case .panel(let rect): return .panel(moved(rect))
        }
    }

    // MARK: paragraphs

    private static func chunks(of paragraphs: [Paragraph]) -> [[Paragraph]] {
        var result: [[Paragraph]] = []
        var current: [Paragraph] = []
        var count = 0
        for paragraph in paragraphs {
            current.append(paragraph)
            count += paragraph.string.length
            if count >= chunkCharacters {
                result.append(current)
                current = []
                count = 0
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func style(
        spaceAfter: CGFloat = 0, spaceBefore: CGFloat = 0, lineSpacing: CGFloat = 3, head: CGFloat = 0, first: CGFloat = 0,
        tab: CGFloat? = nil
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = spaceAfter
        style.paragraphSpacingBefore = spaceBefore
        style.lineBreakMode = .byWordWrapping
        style.headIndent = head
        style.firstLineHeadIndent = first
        if let tab { style.tabStops = [NSTextTab(textAlignment: .left, location: tab)] }
        return style
    }

    private static func paragraph(_ text: String, fonts: ChatFonts, message: ChatMessage) -> Paragraph {
        let shown = text.count > paragraphLimit ? String(text.prefix(paragraphLimit)) + "…" : text
        let string = inline(shown, font: fonts.body, bold: fonts.bold, mono: fonts.mono, color: UIColor.Bandito.text, markdown: message.markdown, style: style(spaceAfter: 8))
        return Paragraph(string: string, spaceAfter: 8)
    }

    private static func heading(_ text: String, level: Int, first: Bool, fonts: ChatFonts) -> Paragraph {
        let font = fonts.heading[min(max(level, 1), 4) - 1]
        let string = inline(text, font: font, bold: font, mono: fonts.mono, color: UIColor.Bandito.text, markdown: true, style: style(spaceAfter: 4, spaceBefore: first ? 0 : 6))
        return Paragraph(string: string, spaceAfter: 4)
    }

    private static func listItem(marker: String, depth: Int, text: String, fonts: ChatFonts) -> Paragraph {
        let indent = CGFloat(depth) * 18
        let markerWidth: CGFloat = marker.count > 2 ? 28 : 20
        let paragraph = style(spaceAfter: 3, lineSpacing: 3, head: indent + markerWidth, first: indent, tab: indent + markerWidth)
        let string = NSMutableAttributedString(
            string: marker + "\t",
            attributes: [.font: fonts.body, .foregroundColor: UIColor.Bandito.text3, .paragraphStyle: paragraph])
        string.append(inline(text, font: fonts.body, bold: fonts.bold, mono: fonts.mono, color: UIColor.Bandito.text, markdown: true, style: paragraph))
        return Paragraph(string: string, spaceAfter: 3)
    }

    private static func quoteParagraph(_ text: String, fonts: ChatFonts) -> Paragraph {
        let string = inline(text, font: fonts.body, bold: fonts.bold, mono: fonts.mono, color: UIColor.Bandito.text2, markdown: true, style: style())
        return Paragraph(string: string, spaceAfter: 0)
    }

    // MARK: inline

    /// The inline Markdown of `source` (emphasis, code, links), with the addresses and file paths in it found.
    static func inline(
        _ source: String, font: UIFont, bold: UIFont, mono: UIFont, color: UIColor, markdown: Bool, style: NSParagraphStyle
    ) -> NSMutableAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let result = NSMutableAttributedString()
        if markdown,
            let parsed = try? AttributedString(
                markdown: source,
                options: .init(
                    allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible))
        {
            for run in parsed.runs {
                var attributes = base
                let intent = run.inlinePresentationIntent ?? []
                if intent.contains(.code) {
                    attributes[.font] = mono
                    attributes[.foregroundColor] = UIColor(AvatarTile.peach)
                } else {
                    if intent.contains(.stronglyEmphasized) { attributes[.font] = bold }
                    if intent.contains(.emphasized) { attributes[.obliqueness] = 0.18 }
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = run.link, ChatLinkSafety.webURL(link) != nil {
                    attributes[.chatLink] = link
                    attributes[.foregroundColor] = UIColor.Bandito.signal
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        } else {
            result.append(NSAttributedString(string: source, attributes: base))
        }
        linkify(result, mono: mono)
        return result
    }

    /// Web addresses become links, and file paths are set in monospace; a Markdown link is left as it is.
    private static func linkify(_ string: NSMutableAttributedString, mono: UIFont) {
        let plain = string.string
        guard plain.contains("/") || plain.contains(".") else { return }
        for link in ChatLinks.find(in: plain) {
            let range = NSRange(link.range, in: plain)
            guard range.location != NSNotFound, range.upperBound <= string.length else { continue }
            if string.attribute(.chatLink, at: range.location, effectiveRange: nil) != nil { continue }
            switch link.target {
            case .url(let address):
                guard let url = URL(string: address), ChatLinkSafety.webURL(url) != nil else { continue }
                string.addAttributes(
                    [
                        .chatLink: url, .foregroundColor: UIColor.Bandito.signal,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ], range: range)
            case .file, .path:
                string.addAttributes([.font: mono, .foregroundColor: UIColor(AvatarTile.peach)], range: range)
            }
        }
    }

    // MARK: code

    private static func codeBlock(language: String?, code: String, width: CGFloat, originY: CGFloat, x: CGFloat, fonts: ChatFonts) -> ChatCodeItem {
        var lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > codeLineLimit {
            lines = Array(lines.prefix(codeLineLimit)) + ["…"]
        }
        let shown = lines.map { $0.count > 400 ? String($0.prefix(400)) + "…" : String($0) }.joined(separator: "\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byClipping
        let display = NSAttributedString(
            string: shown.isEmpty ? " " : shown,
            attributes: [.font: fonts.code, .foregroundColor: UIColor.Bandito.text, .paragraphStyle: paragraph])
        let measured = size(of: display, width: 100_000)
        let header: CGFloat = 30
        let contentHeight = measured.height
        let scrolls = measured.width + 24 > width
        let height = header + 2 + contentHeight + 12
        return ChatCodeItem(
            language: language, code: code, frame: CGRect(x: x, y: originY, width: width, height: height), header: header,
            display: display, contentSize: CGSize(width: measured.width, height: contentHeight), scrolls: scrolls)
    }

    // MARK: files and meta

    private static func layoutFiles(
        _ files: [AgentAttachment], originY: inout CGFloat, metrics: ChatMetrics, fonts: ChatFonts, mine: Bool
    ) -> [ChatFileItem] {
        guard !files.isEmpty else { return [] }
        var items: [ChatFileItem] = []
        let available = metrics.width - metrics.side * 2
        let pictures = files.filter { AttachmentRules.isImage(name: $0.name) }
        let others = files.filter { !AttachmentRules.isImage(name: $0.name) }
        let side = metrics.pictureSide
        let perRow = max(1, Int((available + metrics.pictureGap) / (side + metrics.pictureGap)))
        var index = 0
        while index < pictures.count {
            let rowFiles = Array(pictures[index..<min(index + perRow, pictures.count)])
            let rowWidth = CGFloat(rowFiles.count) * side + CGFloat(rowFiles.count - 1) * metrics.pictureGap
            var x = mine ? metrics.width - metrics.side - rowWidth : metrics.side
            for file in rowFiles {
                items.append(ChatFileItem(file: file, isPicture: true, frame: CGRect(x: x, y: originY, width: side, height: side)))
                x += side + metrics.pictureGap
            }
            originY += side + metrics.pictureGap
            index += perRow
        }
        for file in others {
            let label = NSAttributedString(
                string: file.name, attributes: [.font: fonts.line, .paragraphStyle: truncating()])
            let width = min(available * 0.8, Self.size(of: label, width: 400).width + 28 + 62)
            let x = mine ? metrics.width - metrics.side - width : metrics.side
            items.append(ChatFileItem(file: file, isPicture: false, frame: CGRect(x: x, y: originY, width: width, height: 38)))
            originY += 38 + metrics.pictureGap
        }
        return items
    }

    private static func metaString(_ message: ChatMessage, fonts: ChatFonts) -> NSAttributedString? {
        var parts: [String] = []
        var color = UIColor.Bandito.text3
        switch message.caption {
        case .queued?: parts.append(L10n.Thread.queued)
        case .notDelivered?:
            parts.append(L10n.Thread.notDelivered)
            parts.append(L10n.Message.resend)
            color = UIColor.Bandito.danger
        case .waitingForConnection?: parts.append(L10n.Ios.Chat.waitingForConnection)
        case .sending?: parts.append(L10n.Ios.Chat.sending)
        case .notSent(_, let why)?:
            parts.append(L10n.Ios.Chat.notSent)
            switch why {
            case .key?: parts.append(L10n.Ios.Chat.Failed.key)
            case .insecure?: parts.append(L10n.Ios.Chat.Failed.insecure)
            case .gaveUp?: parts.append(L10n.Ios.Chat.Failed.gaveUp)
            case .refused?, nil: break
            }
            parts.append(L10n.Ios.Chat.retry)
            color = UIColor.Bandito.danger
        case .uncertain?:
            parts.append(L10n.Ios.Chat.uncertain)
            parts.append(L10n.Message.resend)
            color = UIColor.Bandito.danger
        case .viaButton?: parts.append(L10n.Thread.viaButton)
        case nil: break
        }
        if message.showsTime, let ts = message.ts { parts.append(ChatTimeText.short(ts)) }
        guard !parts.isEmpty else { return nil }
        let style = NSMutableParagraphStyle()
        style.alignment = message.isMine ? .right : .left
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(
            string: parts.joined(separator: " · "),
            attributes: [.font: fonts.caption, .foregroundColor: color, .paragraphStyle: style])
    }
}

/// The time under a message: the clock for today, the day and the clock for another day.
enum ChatTimeText {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]

    static func short(_ ms: Int64, now: Date = Date(), calendar: Calendar = .current, locale: Locale = L10n.locale) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let clock = formatter("t", locale: locale, calendar: calendar) { $0.timeStyle = .short; $0.dateStyle = .none }
            .string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = formatter(sameYear ? "d" : "dy", locale: locale, calendar: calendar) {
            $0.setLocalizedDateFormatFromTemplate(sameYear ? "d MMM" : "d MMM yyyy")
        }.string(from: date)
        return day + ", " + clock
    }

    private static func formatter(
        _ name: String, locale: Locale, calendar: Calendar, configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        let key = "\(name)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = formatters[key] { return hit }
        let made = DateFormatter()
        made.locale = locale
        made.calendar = calendar
        made.timeZone = calendar.timeZone
        configure(made)
        formatters[key] = made
        return made
    }
}
