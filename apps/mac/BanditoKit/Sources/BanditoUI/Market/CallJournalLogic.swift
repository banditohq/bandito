import BanditoKit
import BanditoL10n
import Foundation

/// The calls of a service as the "Journal" section shows them: the rows read so far, newest first, and whether there are
/// older ones to ask for. Pure, so the paging is easy to test.
struct CallJournal: Equatable {
    /// How many rows one page asks for.
    static let pageSize = 30

    private(set) var rows: [ToolCallRecord] = []
    /// A page came back full, so older rows may exist.
    private(set) var hasMore = false

    /// The `before` of the next page: the id of the last row read.
    var cursor: Int64? { rows.last?.id }

    /// The first page replaces what was there.
    mutating func replace(with page: [ToolCallRecord]) {
        rows = page
        hasMore = page.count >= Self.pageSize
    }

    /// An older page goes under the rows. A row that is already there (the journal moved while the page was asked for)
    /// is not added twice.
    mutating func append(_ page: [ToolCallRecord]) {
        let known = Set(rows.map(\.id))
        rows += page.filter { !known.contains($0.id) }
        hasMore = page.count >= Self.pageSize
    }
}

/// The words of one journal row and of the statistics line.
enum CallJournalText {
    /// How the call ended.
    enum Outcome: Equatable {
        case succeeded
        /// The first line of the failure, when there is one.
        case failed(String?)
        /// No result came: the turn ended, the process died, or the call is still running.
        case noResult
    }

    static func outcome(_ call: ToolCallRecord) -> Outcome {
        switch call.ok {
        case true?: .succeeded
        case false?: .failed(call.error.flatMap { $0.isEmpty ? nil : $0 })
        case nil: .noResult
        }
    }

    /// "340 ms", "1.2 s", "2 min 5 s"; nil while there is no duration.
    static func duration(_ ms: Int64?) -> String? {
        guard let ms, ms >= 0 else { return nil }
        if ms < 1000 { return L10n.Market.Journal.ms(count: Int(ms)) }
        if ms < 60_000 {
            let seconds = Double(ms) / 1000
            let text = seconds < 10 ? String(format: "%.1f", seconds) : String(Int(seconds.rounded()))
            return L10n.Market.Journal.seconds(value: text)
        }
        return L10n.Market.Journal.minutes(minutes: String(ms / 60_000), seconds: String((ms % 60_000) / 1000))
    }

    /// The time of a call: the clock for today, the date and the clock for another day.
    static func time(
        _ atMs: Int64, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let date = Date(timeIntervalSince1970: Double(atMs) / 1000)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .short
        return formatter.string(from: date)
    }

    static func decision(_ decision: ToolCallDecision) -> String {
        switch decision {
        case .allowed: L10n.Market.Journal.Decision.allowed
        case .asked: L10n.Market.Journal.Decision.asked
        case .denied: L10n.Market.Journal.Decision.denied
        }
    }

    /// "12 calls in 24 hours · 1 error" for a card; nil when the service had no call in the last day. The errors part is
    /// left out when there are none.
    static func statsLine(_ stats: IntegrationCallStats?) -> String? {
        guard let stats, stats.calls24h > 0 else { return nil }
        let calls = L10n.Market.Journal.calls24h(count: stats.calls24h)
        guard stats.errors24h > 0 else { return calls }
        return "\(calls) · \(L10n.Market.Journal.errors24h(count: stats.errors24h))"
    }
}

/// What "Try" says when the call itself did not go through (not when a tool answers with an error: that is an answer).
enum ToolTryFailure {
    static func message(for error: Error) -> UserFacingMessage {
        // The daemon's own sentence says what went wrong (a tool that is not on the list, a service that is off, no answer
        // within 30 seconds); a lost connection or a refusal of the device has its usual words.
        if let rpc = error as? RPCError, case .other = FailureKind.classify(rpc), !rpc.message.isEmpty {
            return UserFacingMessage(text: L10n.Market.Try.failed(message: rpc.message))
        }
        return UserFacingError.message(for: error)
    }
}
