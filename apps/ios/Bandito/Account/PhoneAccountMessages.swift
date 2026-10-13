import BanditoKit
import BanditoL10n
import Foundation

/// The text shown for an error in the account screens. Every string is the app's own translation; the Kit's English
/// descriptions are never shown. (The Mac has the same table in `SignInMessages`.)
enum PhoneAccountMessages {
    static func text(for error: Error) -> String {
        switch error {
        case let error as AccountError: return accountText(error)
        case is DeviceIdentityError, is SecretStoreError, is SyncKeyError, is DeviceTokenSealError:
            return L10n.Onboarding.Account.keyUnavailable
        case let error as SyncStoreError:
            if case .keyMissing = error { return L10n.Ios.Account.Recover.text }
            return L10n.Onboarding.Account.errorGeneric
        default: return L10n.Onboarding.Account.errorGeneric
        }
    }

    /// Shown when the refusal could not remove this iPhone from the account.
    static var refuseFailed: String { L10n.Onboarding.Account.refuseFailed }

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
}
