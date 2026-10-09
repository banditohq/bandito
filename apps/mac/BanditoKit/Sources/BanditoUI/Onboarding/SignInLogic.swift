import BanditoKit
import BanditoL10n
import Foundation

/// The GitHub user code as shown on screen: "WDJB-MJHT" stays as it is, eight plain characters get a hyphen in the middle.
enum UserCodeFormat {
    static func grouped(_ code: String) -> String {
        guard !code.contains("-"), code.count == 8 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 4)
        return String(code[..<middle]) + "-" + String(code[middle...])
    }
}

/// The six boxes of an email code. Digits only; a paste fills from the box it lands in, up to the last box.
struct SixDigitCode: Equatable, Sendable {
    static let length = 6

    private(set) var slots: [String?] = Array(repeating: nil, count: SixDigitCode.length)

    /// The digits typed so far, in order.
    var value: String {
        slots.compactMap { $0 }.joined()
    }

    var isComplete: Bool {
        slots.allSatisfy { $0 != nil }
    }

    /// Types or pastes `text` into box `index`. Anything but ASCII digits is dropped, so "12 34-56" counts as six digits.
    /// Returns true when this input completed the code.
    @discardableResult
    mutating func input(_ text: String, at index: Int) -> Bool {
        let digits = text.filter { $0.isASCII && $0.isNumber }.map(String.init)
        guard !digits.isEmpty, slots.indices.contains(index) else { return isComplete }
        if digits.count == 1 {
            slots[index] = digits[0]
        } else {
            for (offset, digit) in digits.enumerated() where index + offset < slots.count {
                slots[index + offset] = digit
            }
        }
        return isComplete
    }

    mutating func clear(at index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = nil
    }
}

/// The wait before a new email code can be asked for. The server allows a few codes an hour, so the app waits a minute.
struct ResendCooldown: Equatable, Sendable {
    static let seconds = 60

    private(set) var sentAt: Date?

    mutating func markSent(at date: Date) {
        sentAt = date
    }

    /// Whole seconds still to wait, 0 when a new code may be asked for.
    func remaining(now: Date) -> Int {
        guard let sentAt else { return 0 }
        let left = Double(Self.seconds) - now.timeIntervalSince(sentAt)
        return max(0, Int(left.rounded(.up)))
    }
}

/// A light check before sending a code: one "@", something before it, a dot in the domain, no spaces.
/// The server checks the rest.
enum EmailAddressCheck {
    static func isPlausible(_ raw: String) -> Bool {
        let email = raw.trimmingCharacters(in: .whitespaces)
        guard !email.contains(where: \.isWhitespace), let at = email.firstIndex(of: "@") else { return false }
        let local = email[..<at]
        let domain = email[email.index(after: at)...]
        return !local.isEmpty && !domain.isEmpty && domain.contains(".")
            && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }
}

/// The text shown for a sign-in error: the account's own description for `AccountError`, a generic line otherwise.
enum SignInMessages {
    static func text(for error: Error) -> String {
        if let accountError = error as? AccountError, let text = accountError.errorDescription {
            return text
        }
        return L10n.Onboarding.Account.errorGeneric
    }
}
