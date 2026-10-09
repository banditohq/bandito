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
    /// Returns true only when this input completed the code. Input that changes nothing (no digits, no such box)
    /// returns false, so a complete code is never reported twice.
    @discardableResult
    mutating func input(_ text: String, at index: Int) -> Bool {
        let digits = text.filter { $0.isASCII && $0.isNumber }.map(String.init)
        guard !digits.isEmpty, slots.indices.contains(index) else { return false }
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

/// The text shown for an error in the account and sign-in screens. Every string comes from the app's own
/// translations: the Kit's English descriptions are never shown.
enum SignInMessages {
    static func text(for error: Error) -> UserFacingMessage {
        switch error {
        case let accountError as AccountError:
            return UserFacingMessage(text: accountText(accountError))
        case is DeviceIdentityError:
            return UserFacingMessage(text: L10n.Onboarding.Account.keyUnavailable)
        case let hostKey as SSHHostKeyError:
            return UserFacingMessage(text: hostKeyText(hostKey))
        case is DeviceApprovalError:
            return UserFacingMessage(text: L10n.Onboarding.Account.noKeyHere)
        default:
            // Network and unknown failures: the one mapper, so the technical text is one tap away.
            return UserFacingError.message(for: error)
        }
    }

    /// The text for a failure while preparing sign-in (reading this Mac's device key, building the client).
    static func setupText(for error: Error) -> UserFacingMessage {
        if error is DeviceIdentityError {
            return UserFacingMessage(text: L10n.Onboarding.Account.keyUnavailable)
        }
        if error is AccountError {
            return text(for: error)
        }
        return UserFacingMessage(text: L10n.Onboarding.Account.setupFailed)
    }

    static func accountText(_ error: AccountError) -> String {
        switch error {
        case .api(let code, _): return apiText(code)
        case .conflict: return L10n.Onboarding.Failure.conflict
        case .notSignedIn: return L10n.Onboarding.Failure.notSignedIn
        case .network: return L10n.Onboarding.Failure.network
        case .badResponse, .invalidIdentifier: return L10n.Onboarding.Account.errorGeneric
        case .fingerprintMismatch: return L10n.Onboarding.Account.codeMismatch
        case .insecureBaseURL: return L10n.Onboarding.Failure.insecureBaseURL
        }
    }

    /// The server's answer codes (docs/ACCOUNTS_API.md#errors). An unknown code gets the generic text.
    static func apiText(_ code: String) -> String {
        switch code {
        case "invalid": return L10n.Onboarding.Failure.invalid
        case "bad_json": return L10n.Onboarding.Failure.badJson
        case "bad_device_proof": return L10n.Onboarding.Failure.badDeviceProof
        case "ip_required": return L10n.Onboarding.Failure.ipRequired
        case "unauthorized": return L10n.Onboarding.Failure.unauthorized
        case "github_invalid": return L10n.Onboarding.Failure.githubInvalid
        case "code_invalid": return L10n.Onboarding.Failure.codeInvalid
        case "device_not_approved": return L10n.Onboarding.Failure.deviceNotApproved
        case "access_denied": return L10n.Onboarding.Failure.accessDenied
        case "session_too_old": return L10n.Onboarding.Failure.sessionTooOld
        case "not_found": return L10n.Onboarding.Failure.notFound
        case "not_yet": return L10n.Onboarding.Failure.notYet
        case "flow_not_found", "expired": return L10n.Onboarding.Failure.flowNotFound
        case "already_approved": return L10n.Onboarding.Failure.alreadyApproved
        case "account_conflict": return L10n.Onboarding.Failure.accountConflict
        case "key_mismatch": return L10n.Onboarding.Failure.keyMismatch
        case "last_device": return L10n.Onboarding.Failure.lastDevice
        case "rate": return L10n.Onboarding.Failure.rate
        case "email_failed": return L10n.Onboarding.Failure.emailFailed
        case "email_unavailable": return L10n.Onboarding.Failure.emailUnavailable
        case "github_failed": return L10n.Onboarding.Failure.githubFailed
        case "github_unavailable": return L10n.Onboarding.Failure.githubUnavailable
        case "too_large": return L10n.Onboarding.Failure.tooLarge
        case "server": return L10n.Onboarding.Failure.server
        default: return L10n.Onboarding.Account.errorGeneric
        }
    }

    static func hostKeyText(_ error: SSHHostKeyError) -> String {
        switch error {
        case .noKey: return L10n.Onboarding.Server.hostKeyScanFailed
        case .viaProxy: return L10n.Onboarding.Server.viaProxy
        case .changedBetweenChecks: return L10n.Onboarding.Server.hostKeyChangedWhileReviewing
        case .readFailed: return L10n.Onboarding.Failure.hostKeyReadFailed
        case .writeFailed: return L10n.Onboarding.Failure.hostKeyWriteFailed
        case .keyChangedSincePreviousVisit: return L10n.Onboarding.Failure.knownHostConflict
        }
    }
}
