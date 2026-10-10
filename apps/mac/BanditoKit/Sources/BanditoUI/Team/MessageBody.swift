import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The text of a message in its bubble. Running text is drawn as before (one `Text`, with inline Markdown for the
/// agent); each fenced code block is a box of its own with a Copy button in the corner.
struct MessageBodyView: View {
    var text: String
    /// Inline Markdown (the agent's messages); the person's own text is shown as typed.
    var markdown: Bool
    /// A text still streaming in is drawn without the cache.
    var streaming = false

    var body: some View {
        let blocks = MessageRenderCache.shared.blocks(for: text, markdown: markdown, cached: !streaming)
        if blocks.contains(where: { if case .code = $0 { return true } else { return false } }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let running):
                        runningText(running)
                    case .code(let language, let code):
                        CodeBlockView(language: language, code: code)
                    }
                }
            }
        } else if let first = blocks.first, case .text(let running) = first {
            runningText(running)
        }
    }

    private func runningText(_ value: AttributedString) -> some View {
        Text(value)
            .font(BanditoFont.text(size: 14.5, weight: 400))
            .foregroundStyle(Color.Bandito.text)
            .lineSpacing(markdown ? 4 : 3)
            .textSelection(.enabled)
    }
}

/// A message ready to draw: its text already parsed (Markdown, links), its code blocks split off.
enum RenderedBlock {
    case text(AttributedString)
    case code(language: String?, code: String)
}

/// The parsed bodies of messages, by text. Parsing Markdown and finding links is the costly part of drawing a bubble;
/// it must not be redone every time a row is built (a scroll builds rows again and again). Bounded by size (8 MB of text), and a
/// message still streaming is never kept: its text changes at every token.
final class MessageRenderCache: @unchecked Sendable {
    static let shared = MessageRenderCache()

    private struct Entry {
        let blocks: [RenderedBlock]
        let cost: Int
        var used: UInt64
    }
    /// A plain LRU bounded by text size. NSCache dropped entries under memory pressure at will, and a dropped body is
    /// parsed again on the next draw: exactly the work this cache is for.
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var totalCost = 0
    private var tick: UInt64 = 0
    private let limit: Int
    private var parsedCount = 0

    init(limit: Int = 8 << 20) { self.limit = limit }

    /// How many times a body was parsed (for tests).
    var parses: Int { lock.withLock { parsedCount } }

    func blocks(for text: String, markdown: Bool, cached: Bool = true) -> [RenderedBlock] {
        guard cached else {
            lock.withLock { parsedCount += 1 }
            return Self.build(text, markdown: markdown)
        }
        let key = (markdown ? "m:" : "p:") + text
        if let hit = lock.withLock({ () -> [RenderedBlock]? in
            guard var entry = entries[key] else { return nil }
            tick += 1
            entry.used = tick
            entries[key] = entry
            return entry.blocks
        }) {
            return hit
        }
        let built = Self.build(text, markdown: markdown)
        lock.withLock {
            parsedCount += 1
            tick += 1
            let cost = text.utf8.count
            if let old = entries.updateValue(Entry(blocks: built, cost: cost, used: tick), forKey: key) {
                totalCost -= old.cost
            }
            totalCost += cost
            // Evict the least recently used until under the limit (rare: the limit holds thousands of messages).
            while totalCost > limit, entries.count > 1,
                let oldest = entries.min(by: { $0.value.used < $1.value.used })
            {
                totalCost -= oldest.value.cost
                entries.removeValue(forKey: oldest.key)
            }
        }
        return built
    }

    static func build(_ text: String, markdown: Bool) -> [RenderedBlock] {
        func running(_ value: String) -> AttributedString {
            ChatLinkText.linked(markdown ? InlineMarkdown.render(value) : AttributedString(value))
        }
        let blocks = MessageBlocks.parse(text)
        if !blocks.contains(where: { if case .code = $0 { return true } else { return false } }) {
            return [.text(running(text))]
        }
        return blocks.map { block in
            switch block {
            case .text(let value): return .text(running(value))
            case .code(let language, let code, _): return .code(language: language, code: code)
            }
        }
    }
}

/// A fenced code block: the language in the corner, the code in monospace (a long line scrolls sideways), and a Copy
/// button that says "Copied" for a moment.
struct CodeBlockView: View {
    var language: String?
    var code: String

    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "")
                    .font(BanditoFont.mono(size: 11, weight: 500))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                copyButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.top, 6)

            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(BanditoFont.mono(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
        .onDisappear { reset?.cancel() }
    }

    private var copyButton: some View {
        Button {
            SystemActions.copy(code)
            copied = true
            reset?.cancel()
            reset = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { copied = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(copied ? L10n.Message.copied : L10n.Thread.copy)
                    .font(BanditoFont.text(size: 11.5, weight: 500))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(copied ? Color.Bandito.ok : Color.Bandito.text2)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 7))
        .help(L10n.Thread.copy)
    }
}

/// The message a reply answers, quoted at the top of the reply: a bar in the agent's colour, the sender and the first
/// lines. A click goes to the original.
struct ReplyQuoteView: View {
    var name: String
    /// Nil when the original is not loaded (it is older than the history on screen).
    var text: String?
    var accent: Color
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    if !name.isEmpty {
                        Text(name)
                            .font(BanditoFont.text(size: 11.5, weight: 600))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                    }
                    Text(text.map { MessageBlocks.plainText($0) } ?? L10n.Reply.earlier)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 8))
        .help(L10n.Reply.jump)
        .accessibilityLabel("\(name) \(text.map { MessageBlocks.excerpt($0, limit: 80) } ?? L10n.Reply.earlier)")
    }
}
