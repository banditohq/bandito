import BanditoKit
import BanditoL10n
import Foundation

/// What a Telegram failure means in words. The daemon sends one of four codes (as `data.reason` or at the start of the
/// message); anything else is the general failure of the app.
enum TelegramFailure: Equatable {
    case invalidToken, conflict, unauthorized, network
    case other(UserFacingMessage)

    init?(code: String) {
        switch code {
        case "invalid_token": self = .invalidToken
        case "conflict": self = .conflict
        case "unauthorized": self = .unauthorized
        case "network": self = .network
        default: return nil
        }
    }

    var message: UserFacingMessage {
        switch self {
        case .invalidToken: UserFacingMessage(text: L10n.Settings.Telegram.Error.invalidToken)
        case .conflict: UserFacingMessage(text: L10n.Settings.Telegram.Error.conflict)
        case .unauthorized: UserFacingMessage(text: L10n.Settings.Telegram.Error.unauthorized)
        case .network: UserFacingMessage(text: L10n.Settings.Telegram.Error.network)
        case .other(let message): message
        }
    }
}

/// The pure rules of the Telegram section: what the token field sends, when Connect is on, how long a link code has left
/// and which failure a reply means. Kept out of the views so they can be tested.
enum TelegramRules {
    /// The token as it is sent: spaces and line breaks around it are removed (a paste often brings them).
    static func token(from draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Connect is on for a token that is not empty, and only while no request runs (a second click is not a second request).
    static func canConnect(draft: String, busy: Bool) -> Bool {
        !busy && !token(from: draft).isEmpty
    }

    /// Milliseconds from `now` to `expiresAt`, never below zero.
    static func remainingMs(until expiresAt: Int64, now: Int64) -> Int64 {
        max(0, expiresAt - now)
    }

    /// Unix milliseconds of a date.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    /// `m:ss` for a count of milliseconds. Rounds up, so the last second still shows.
    static func countdown(remainingMs: Int64) -> String {
        let seconds = (max(0, remainingMs) + 999) / 1000
        let rest = seconds % 60
        return "\(seconds / 60):\(rest < 10 ? "0" : "")\(rest)"
    }

    /// True when `current` has a chat that `known` did not have: the link the sheet was waiting for is in.
    static func hasNewChat(known: Set<Int64>, current: [TelegramChat]) -> Bool {
        current.contains { !known.contains($0.chatId) }
    }

    /// The failure an error means. A daemon code arrives as `data.reason` or as the first word of the message; a
    /// failure without one of the four codes is shown as the general failure.
    static func failure(for error: Error) -> TelegramFailure {
        if let rpc = error as? RPCError {
            let candidates = [rpc.reason, firstWord(of: rpc.message)].compactMap { $0 }
            for code in candidates {
                if let failure = TelegramFailure(code: code) { return failure }
            }
        }
        return .other(UserFacingError.message(for: error))
    }

    /// The failure the status reports for the bot, if any.
    static func problem(of status: TelegramStatus) -> TelegramFailure? {
        status.lastError.flatMap { TelegramFailure(code: $0) }
    }

    /// The date a chat was linked, as the person's locale writes it.
    static func linkedDate(_ linkedAtMs: Int64) -> String {
        Date(timeIntervalSince1970: Double(linkedAtMs) / 1000).formatted(date: .abbreviated, time: .omitted)
    }

    /// The word before a colon or a space: `invalid_token: bad` gives `invalid_token`.
    private static func firstWord(of text: String) -> String? {
        let head = text.split(whereSeparator: { $0 == ":" || $0 == " " }).first
        return head.map(String.init)
    }
}
