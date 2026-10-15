import BanditoKit
import Foundation
import UIKit

/// What the long press on a message offers. Pure: the cell turns each entry into a menu action. The set is the Mac's
/// (reply, react, send again, copy, select text), with Share; what the protocol cannot do for a message is left out: a
/// message with no `seq` (a stream, a teammate's, one still on this phone) takes no reaction and no reply, a server
/// without the feature takes none either.
enum ChatMessageMenu {
    enum Item: Equatable {
        case openLink(URL)
        case copyLink(URL)
        /// The row of quick reactions.
        case reactions
        case reply
        /// The daemon gave up on the message: send it again.
        case resend(seq: Int64)
        /// The message is still on this phone and was refused or is not sure to have arrived.
        case retry(queueID: String)
        case discard(queueID: String)
        case copy
        /// Only for an agent's message whose Markdown differs from what it shows.
        case copyMarkdown
        case selectText
        case share
    }

    static func items(for message: ChatMessage, link: URL?, plain: String) -> [Item] {
        var items: [Item] = []
        if let link {
            items.append(.openLink(link))
            items.append(.copyLink(link))
        }
        switch message.caption {
        case .notSent(let id, _)?, .uncertain(let id)?:
            items.append(.retry(queueID: id))
            items.append(.discard(queueID: id))
            items.append(.copy)
            items.append(.selectText)
            items.append(.share)
            return items
        default:
            break
        }
        if message.canReact, message.seq != nil { items.append(.reactions) }
        if message.canReply, message.seq != nil { items.append(.reply) }
        if case .notDelivered(let seq)? = message.caption { items.append(.resend(seq: seq)) }
        items.append(.copy)
        if message.markdown, message.text != plain { items.append(.copyMarkdown) }
        items.append(.selectText)
        items.append(.share)
        return items
    }

    /// The quick reactions cut into rows of `perRow` (the menu's palette shows about six small buttons across; a longer row
    /// scrolls sideways and the last ones are not seen). Every reaction is in exactly one row, in the Mac's order.
    static func paletteRows(perRow: Int = 6, from emoji: [String] = ReactionRules.common) -> [[String]] {
        guard perRow > 0 else { return [emoji] }
        return stride(from: 0, to: emoji.count, by: perRow).map { Array(emoji[$0..<min($0 + perRow, emoji.count)]) }
    }

    /// The emoji the person's own reaction on a message is, when there is one.
    static func mine(_ message: ChatMessage) -> String? {
        message.reactions.first { $0.byUser }?.emoji
    }

    /// The reaction a pick of `emoji` asks for: the person's own again takes it off.
    static func pick(_ emoji: String, mine: String?) -> String? {
        emoji == mine ? nil : emoji
    }

    /// The reaction a tap on a chip asks for: the person's own chip takes it off, the agent's chip is put there as the
    /// person's own.
    static func tap(_ chip: ChatReactionChip) -> String? {
        chip.byUser ? nil : chip.emoji
    }
}

/// The reactions as the screen shows them before the daemon's event comes back: the person's own is already what they
/// asked for. Pure.
enum ChatReactionsRules {
    /// `chips` with the person's reaction replaced by `desired` (nil: taken off). The person's chip comes first; an
    /// agent's reaction with the same emoji shares the chip.
    static func applying(_ desired: String??, to chips: [ChatReactionChip]) -> [ChatReactionChip] {
        guard let desired else { return chips }
        let agent = chips.first { $0.byAgent }?.emoji
        var result: [ChatReactionChip] = []
        if let emoji = desired {
            result.append(ChatReactionChip(emoji: emoji, byUser: true, byAgent: emoji == agent))
        }
        if let agent, agent != desired {
            result.append(ChatReactionChip(emoji: agent, byUser: false, byAgent: true))
        }
        return result
    }

    /// Whether the thread already shows what the person asked for (so the stand-in is no longer needed).
    static func settled(_ desired: String?, in chips: [ChatReactionChip]) -> Bool {
        chips.first { $0.byUser }?.emoji == desired
    }
}

/// The emoji of the quick reactions drawn as small pictures for the menu's palette (an action can only carry an image).
@MainActor
enum ChatEmojiImages {
    private static var cache: [String: UIImage] = [:]

    static func image(_ emoji: String, size: CGFloat = 26) -> UIImage {
        let key = "\(emoji)|\(size)"
        if let hit = cache[key] { return hit }
        let canvas = CGSize(width: size + 6, height: size + 6)
        let image = UIGraphicsImageRenderer(size: canvas).image { _ in
            let font = UIFont.systemFont(ofSize: size - 4)
            let string = NSAttributedString(string: emoji, attributes: [.font: font])
            let bounds = string.boundingRect(with: canvas, options: [.usesLineFragmentOrigin], context: nil)
            string.draw(at: CGPoint(x: (canvas.width - bounds.width) / 2, y: (canvas.height - bounds.height) / 2))
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image
        return image
    }
}
