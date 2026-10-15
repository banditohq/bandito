import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// What the long press on a message offers, by the kind of message (the Mac's set, less what the protocol cannot do).
@Suite struct ChatMessageMenuTests {
    func message(
        _ sender: ChatMessage.Sender = .agent, seq: Int64? = 7, caption: ChatMessage.Caption? = nil, streaming: Bool = false,
        react: Bool = true, reply: Bool = true, text: String = "Hello **there**", reactions: [ChatReactionChip] = []
    ) -> ChatMessage {
        var message = ChatMessage(
            sender: sender, text: text, streaming: streaming, ts: 1, showsTime: false, files: [], caption: caption, tail: true, seq: seq)
        message.canReact = react
        message.canReply = reply
        message.reactions = reactions
        return message
    }

    func items(_ message: ChatMessage, link: URL? = nil, plain: String = "Hello there") -> [ChatMessageMenu.Item] {
        ChatMessageMenu.items(for: message, link: link, plain: plain)
    }

    @Test func anAgentsMessageHasTheWholeSet() {
        #expect(items(message(.agent)) == [.reactions, .reply, .copy, .copyMarkdown, .selectText, .share])
    }

    @Test func theMarkdownCopyIsOnlyForTextThatDiffersFromWhatShows() {
        #expect(items(message(.agent, text: "Hello there"), plain: "Hello there") == [.reactions, .reply, .copy, .selectText, .share])
        // The person's own words are never Markdown.
        #expect(items(message(.me, text: "Hello **there**")) == [.reactions, .reply, .copy, .selectText, .share])
    }

    @Test func aPersonsOwnMessageTakesReactionsAndReplies() {
        let found = items(message(.me))
        #expect(found.contains(.reactions) && found.contains(.reply))
    }

    @Test func aMessageWithNoSeqTakesNoReactionAndNoReply() {
        // A stream, a teammate's message, one still on this phone.
        for sender in [ChatMessage.Sender.agent, .me, .crew(from: "Forge")] {
            let found = items(message(sender, seq: nil), plain: "Hello **there**")
            #expect(!found.contains(.reactions) && !found.contains(.reply))
            #expect(found == [.copy, .selectText, .share])
        }
        let stream = items(message(.agent, seq: nil, streaming: true))
        #expect(!stream.contains(.reactions))
    }

    @Test func aServerWithoutTheFeatureOffersNeither() {
        #expect(items(message(react: false, reply: false), plain: "Hello **there**") == [.copy, .selectText, .share])
        #expect(items(message(react: true, reply: false), plain: "Hello **there**") == [.reactions, .copy, .selectText, .share])
        #expect(items(message(react: false, reply: true), plain: "Hello **there**") == [.reply, .copy, .selectText, .share])
    }

    @Test func aMessageTheDaemonGaveUpOnCanBeSentAgain() {
        let found = items(message(.me, caption: .notDelivered(seq: 7)), plain: "Hello **there**")
        #expect(found == [.reactions, .reply, .resend(seq: 7), .copy, .selectText, .share])
    }

    @Test func aMessageStillOnThisPhoneOffersRetryAndDiscardAndNeitherReactionNorReply() {
        let refused = items(message(.me, seq: nil, caption: .notSent(id: "q1", why: nil)), plain: "Hello **there**")
        #expect(refused == [.retry(queueID: "q1"), .discard(queueID: "q1"), .copy, .selectText, .share])
        let unsure = items(message(.me, seq: nil, caption: .uncertain(id: "q2")), plain: "Hello **there**")
        #expect(unsure == [.retry(queueID: "q2"), .discard(queueID: "q2"), .copy, .selectText, .share])
        // Even with a seq the set of a queued message holds no reaction.
        #expect(!items(message(.me, seq: 3, caption: .uncertain(id: "q3"))).contains(.reactions))
    }

    @Test func aWaitingMessageHasTheOrdinarySet() {
        let waiting = items(message(.me, seq: nil, caption: .waitingForConnection), plain: "Hello **there**")
        #expect(waiting == [.copy, .selectText, .share])
    }

    @Test func aLinkComesFirst() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let found = items(message(), link: url)
        #expect(Array(found.prefix(2)) == [.openLink(url), .copyLink(url)])
        #expect(found.contains(.reactions))
    }

    // MARK: reactions

    @Test func theQuickReactionsFitTheMenuInRowsOfSixWithNoneLost() {
        let rows = ChatMessageMenu.paletteRows()
        #expect(rows.map(\.count) == [6, 6, 4])
        #expect(rows.flatMap { $0 } == ReactionRules.common)
        #expect(Set(rows.flatMap { $0 }).count == ReactionRules.common.count)
        #expect(ChatMessageMenu.paletteRows(perRow: 0) == [ReactionRules.common])
        #expect(ChatMessageMenu.paletteRows(from: []) == [])
    }

    @Test func theSameEmojiTakesTheReactionOff() {
        #expect(ChatMessageMenu.pick("👍", mine: "👍") == nil)
        #expect(ChatMessageMenu.pick("🔥", mine: "👍") == "🔥")
        #expect(ChatMessageMenu.pick("🔥", mine: nil) == "🔥")
    }

    @Test func theOwnReactionIsTheOneTheMenuMarks() {
        let chips = [ChatReactionChip(emoji: "👍", byUser: false, byAgent: true), ChatReactionChip(emoji: "🔥", byUser: true, byAgent: false)]
        #expect(ChatMessageMenu.mine(message(reactions: chips)) == "🔥")
        #expect(ChatMessageMenu.mine(message(reactions: [chips[0]])) == nil)
    }

    @Test func aTapOnAChipTakesOffTheOwnAndPutsTheAgentsOnAsTheOwn() {
        #expect(ChatMessageMenu.tap(ChatReactionChip(emoji: "🔥", byUser: true, byAgent: false)) == nil)
        #expect(ChatMessageMenu.tap(ChatReactionChip(emoji: "👍", byUser: false, byAgent: true)) == "👍")
        #expect(ChatMessageMenu.tap(ChatReactionChip(emoji: "👍", byUser: true, byAgent: true)) == nil)
    }

    @Test func theAskedReactionShowsBeforeTheDaemonAnswers() {
        let agent = ChatReactionChip(emoji: "👍", byUser: false, byAgent: true)
        // Nothing asked: as it is.
        #expect(ChatReactionsRules.applying(nil, to: [agent]) == [agent])
        // The person's own comes first; the agent's stays.
        #expect(ChatReactionsRules.applying(.some("🔥"), to: [agent]) == [ChatReactionChip(emoji: "🔥", byUser: true, byAgent: false), agent])
        // The same emoji as the agent's shares the chip.
        #expect(ChatReactionsRules.applying(.some("👍"), to: [agent]) == [ChatReactionChip(emoji: "👍", byUser: true, byAgent: true)])
        // Taken off.
        let both = ChatReactionChip(emoji: "👍", byUser: true, byAgent: true)
        #expect(ChatReactionsRules.applying(.some(nil), to: [both]) == [ChatReactionChip(emoji: "👍", byUser: false, byAgent: true)])
        #expect(ChatReactionsRules.applying(.some(nil), to: []) == [])
    }

    @Test func theStandInIsLetGoWhenTheThreadShowsTheSame() {
        let mine = ChatReactionChip(emoji: "🔥", byUser: true, byAgent: false)
        #expect(ChatReactionsRules.settled("🔥", in: [mine]))
        #expect(!ChatReactionsRules.settled("👍", in: [mine]))
        #expect(ChatReactionsRules.settled(nil, in: []))
        #expect(!ChatReactionsRules.settled(nil, in: [mine]))
    }
}
