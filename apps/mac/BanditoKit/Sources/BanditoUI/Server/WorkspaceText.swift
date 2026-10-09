import BanditoKit
import BanditoL10n
import Foundation

/// Sentences for workplace failures (`WorkspaceFailure`, error code -32028). Other errors keep their own text.
enum WorkspaceText {
    /// The sentence for a workplace failure, or nil when `error` is not one.
    static func failure(_ error: Error) -> String? {
        guard let failure = WorkspaceFailure(error) else { return nil }
        switch failure {
        case .dockerUnavailable: return L10n.Workspace.Error.dockerUnavailable
        case .notFound: return L10n.Workspace.Error.notFound
        case .builtin: return L10n.Workspace.Error.builtin
        case .notEmpty: return L10n.Workspace.Error.notEmpty
        case .invalid(let message):
            // The daemon refuses a folder that holds its own data; the text is its English sentence.
            if message.contains("Bandito's own data") { return L10n.Workspace.Error.banditoData }
            return L10n.Workspace.Error.invalid(message: message)
        case .docker(let message): return L10n.Workspace.Error.docker(message: message)
        case .other(let message): return L10n.Workspace.Error.other(message: message)
        }
    }

    /// The workplace sentence when there is one, else the error's own description.
    static func message(for error: Error) -> String {
        failure(error) ?? error.localizedDescription
    }
}
