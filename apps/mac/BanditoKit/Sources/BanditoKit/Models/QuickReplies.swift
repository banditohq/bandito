import Foundation

// The buttons an agent shows under its last message: docs/ARCHITECTURE.md#quick-replies.

/// One button: the label on it, and the text that is sent as the person's message when it is pressed.
public struct QuickReplyButton: Codable, Sendable, Hashable {
    public var label: String
    public var reply: String

    public init(label: String, reply: String) {
        self.label = label
        self.reply = reply
    }
}

/// A button that opens a page. The daemon sends https addresses only; the app checks again before it opens one.
public struct QuickReplyLink: Codable, Sendable, Hashable {
    public var label: String
    public var url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

/// "2 of 6": where the person is in a multi-step setup.
public struct QuickReplyProgress: Codable, Sendable, Hashable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    /// A progress that makes sense to show: at least one step, and no more done than there are.
    public var isValid: Bool { total >= 1 && done >= 0 && done <= total }
}

/// The set of quick replies a thread shows now: the newest `agent.quick_replies` event, until the person writes
/// something themselves, a new turn begins, or a newer set comes.
public struct QuickReplies: Sendable, Hashable, Identifiable {
    public var buttons: [QuickReplyButton]
    public var link: QuickReplyLink?
    public var progress: QuickReplyProgress?
    /// The `seq` of the event, which tells one set from the next.
    public var seq: Int64
    /// Unix milliseconds.
    public var ts: Int64

    public var id: String { "quick-\(seq)" }

    public init(
        buttons: [QuickReplyButton], link: QuickReplyLink? = nil, progress: QuickReplyProgress? = nil, seq: Int64 = 0,
        ts: Int64 = 0
    ) {
        self.buttons = buttons
        self.link = link
        self.progress = progress
        self.seq = seq
        self.ts = ts
    }
}
