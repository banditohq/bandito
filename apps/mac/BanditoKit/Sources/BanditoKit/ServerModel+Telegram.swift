import Foundation

// The Telegram bot of this server: approvals and agent replies go to the chats linked to it, and the owner writes to
// the agents from there. Owner and app methods only. Needs a daemon from 0.1.8 (`method not found` otherwise).

/// Whether a daemon knows the Telegram RPCs: `unknown` until the probe has answered, then `supported` or `unsupported`.
public enum TelegramSupport: Sendable, Hashable {
    case unknown, supported, unsupported
}

/// The bot the daemon polls. `username` has no `@`.
public struct TelegramBot: Codable, Sendable, Hashable {
    public var username: String
    public var name: String

    public init(username: String, name: String) {
        self.username = username
        self.name = name
    }
}

/// Which of an agent's replies go to a chat: all of them, only the turns started from Telegram, or none.
public enum TelegramAnswers: String, Codable, Sendable, Hashable, CaseIterable {
    case all, telegram, none
}

/// A private chat linked to the bot.
public struct TelegramChat: Codable, Sendable, Hashable, Identifiable {
    public var chatId: Int64
    public var title: String
    /// The language the daemon writes this chat in (one of the nine the bot speaks).
    public var language: String
    /// When the chat was linked (Unix milliseconds).
    public var linkedAt: Int64
    /// Whether approval requests are sent to this chat.
    public var approvals: Bool
    public var answers: TelegramAnswers

    public var id: Int64 { chatId }

    public init(
        chatId: Int64, title: String, language: String, linkedAt: Int64, approvals: Bool, answers: TelegramAnswers
    ) {
        self.chatId = chatId
        self.title = title
        self.language = language
        self.linkedAt = linkedAt
        self.approvals = approvals
        self.answers = answers
    }
}

/// The Telegram state of this server (`telegram.status`).
public struct TelegramStatus: Codable, Sendable, Hashable {
    /// A token is saved on the server.
    public var configured: Bool
    public var bot: TelegramBot?
    /// The daemon is polling the bot now.
    public var running: Bool
    /// Why polling stopped or is failing: `unauthorized`, `conflict` or `network`. Nil when all is well.
    public var lastError: String?
    public var chats: [TelegramChat]

    public init(configured: Bool, bot: TelegramBot?, running: Bool, lastError: String?, chats: [TelegramChat]) {
        self.configured = configured
        self.bot = bot
        self.running = running
        self.lastError = lastError
        self.chats = chats
    }
}

/// A code that links one chat: the person opens `url` in Telegram (or scans it as a QR code) and presses Start.
public struct TelegramLink: Codable, Sendable, Hashable {
    public var code: String
    public var url: String
    /// When the code stops working (Unix milliseconds). A new request replaces the code.
    public var expiresAt: Int64

    public init(code: String, url: String, expiresAt: Int64) {
        self.code = code
        self.url = url
        self.expiresAt = expiresAt
    }
}

extension ServerModel {
    /// The bot and the linked chats (`telegram.status`).
    public func telegramStatus() async throws -> TelegramStatus {
        try await rpc().call("telegram.status", NoParams(), as: TelegramStatus.self)
    }

    /// Saves the bot token, checks it with Telegram and starts polling. Returns the new status. A refused token is
    /// `invalid_token`. The app keeps no copy of the token: the caller clears its field once this succeeds.
    public func telegramSetToken(_ token: String) async throws -> TelegramStatus {
        struct P: Encodable { var token: String }
        return try await rpc().call("telegram.set_token", P(token: token), as: TelegramStatus.self, timeout: .seconds(60))
    }

    /// Stops polling, deletes the token and unlinks every chat.
    public func telegramRemoveToken() async throws {
        try await rpc().call("telegram.remove_token", NoParams(), timeout: .seconds(30))
    }

    /// Makes a new link code for one chat (`telegram.link_start`). A new call replaces the previous code.
    public func telegramLinkStart() async throws -> TelegramLink {
        try await rpc().call("telegram.link_start", NoParams(), as: TelegramLink.self, timeout: .seconds(30))
    }

    /// Unlinks one chat. The daemon says goodbye in that chat first.
    public func telegramUnlink(chatId: Int64) async throws {
        struct P: Encodable { var chatId: Int64 }
        try await rpc().call("telegram.unlink", P(chatId: chatId), timeout: .seconds(30))
    }

    /// Changes what one chat receives. A nil value is left as it is.
    public func telegramUpdateChat(chatId: Int64, approvals: Bool? = nil, answers: TelegramAnswers? = nil) async throws {
        struct P: Encodable {
            var chatId: Int64
            var approvals: Bool?
            var answers: String?
        }
        let params = P(chatId: chatId, approvals: approvals, answers: answers?.rawValue)
        try await rpc().call("telegram.update_chat", params, timeout: .seconds(30))
    }

    /// Asks whether this daemon knows the Telegram RPCs. A daemon from before 0.1.8 answers `method not found`, which
    /// sets `telegramSupport` to `unsupported`. Any other failure (not connected, link dropped) keeps the last answer,
    /// which is `unknown` until the first real one.
    public func checkTelegramSupport() async {
        do {
            _ = try await telegramStatus()
            telegramSupport = .supported
        } catch let error as RPCError where error.code == RPCError.methodNotFound {
            telegramSupport = .unsupported
        } catch {
            // Not connected, or the link dropped: the last answer stands.
        }
    }
}
