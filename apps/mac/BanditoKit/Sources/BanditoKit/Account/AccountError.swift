import Foundation

/// A failed call to the accounts API. `api` carries the `error` code of docs/ACCOUNTS_API.md, so screens
/// can localize by code; `errorDescription` is the English fallback.
public enum AccountError: Error, Sendable, Equatable, LocalizedError {
    /// The server refused the request with this `error` code and HTTP status.
    case api(code: String, status: Int)
    /// A sync write lost a race. `current` is the version on the server now.
    case conflict(current: Int)
    /// No stored session: sign in first.
    case notSignedIn
    /// The request got no answer (offline, TLS, timeout).
    case network(String)
    /// An answer that does not match the contract.
    case badResponse
    /// The code shown on the pending device does not match its public key. Nothing was sent.
    case fingerprintMismatch
    /// The base URL is not `https://bandito.dev` (or `http` to a loopback host, for local development).
    case insecureBaseURL
    /// An ID would not be a single safe URL path segment (`^[A-Za-z0-9_-]{1,128}$`). Nothing was sent.
    case invalidIdentifier

    public var errorDescription: String? {
        switch self {
        case .api(let code, _):
            return Self.describe(code)
        case .conflict:
            return "Your data changed on another device. Try again."
        case .notSignedIn:
            return "Sign in first."
        case .network(let detail):
            return "No connection to bandito.dev (\(detail))."
        case .badResponse:
            return "bandito.dev sent an answer the app does not understand."
        case .fingerprintMismatch:
            return "The code on the new device does not match its key. Do not approve it."
        case .insecureBaseURL:
            return "The accounts server must be reached over https://bandito.dev."
        case .invalidIdentifier:
            return "The identifier is not valid."
        }
    }

    static func describe(_ code: String) -> String {
        switch code {
        case "invalid": return "The server rejected the request as invalid."
        case "bad_json": return "The request could not be read by the server."
        case "bad_device_proof": return "Sign-in could not be verified. Try again."
        case "ip_required": return "The server could not identify this connection. Try again."
        case "unauthorized": return "Your session has ended. Sign in again."
        case "github_invalid": return "GitHub rejected the authorization. Try again."
        case "code_invalid": return "The code is wrong or has expired."
        case "device_not_approved": return "This device is waiting for approval from another device."
        case "access_denied": return "GitHub sign-in was declined."
        case "session_too_old": return "Sign in again, then reset your account."
        case "not_found": return "Not found."
        case "not_yet": return "The key is not ready yet."
        case "flow_not_found", "expired": return "The GitHub sign-in has expired. Start again."
        case "already_approved": return "This device is already approved."
        case "account_conflict": return "This GitHub account does not match the account for this email."
        case "key_mismatch": return "This device's key does not match the one it was registered with."
        case "last_device": return "This is the last approved device. Confirm the reset to remove it."
        case "rate": return "Too many attempts. Try again later."
        case "email_failed": return "The email could not be sent. Try again."
        case "email_unavailable": return "Email sign-in is not available right now."
        case "github_failed": return "GitHub did not answer as expected. Try again."
        case "github_unavailable": return "GitHub is unreachable. Try again later."
        case "too_large": return "The data is too large to store."
        case "server": return "Something went wrong on the server. Try again."
        default: return "The server refused the request (\(code))."
        }
    }
}
