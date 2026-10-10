import BanditoKit
import BanditoL10n
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// A sign-in to a service in the browser (docs/ARCHITECTURE.md#integrations). The daemon does the sign-in; this
/// only starts it, opens the address, takes `bandito://oauth/callback` back and hands the code over. One sign-in is
/// in progress at a time. The app remembers which server began it, and keeps that on disk for ten minutes, so a
/// callback that finds the app restarted still reaches the right server.
@MainActor
@Observable
public final class OAuthSignIn {
    public enum Phase: Equatable {
        case idle
        /// Asking the server for the address.
        case starting(name: String)
        /// The browser is open; the owner is allowing access there.
        case waiting(name: String)
        /// The code is back and the server trades it.
        case finishing(name: String)
        case connected(name: String, integrationID: String)
        case failed(name: String, message: UserFacingMessage, canRetry: Bool)
    }

    public private(set) var phase: Phase = .idle

    /// A sign-in the browser has not answered yet.
    struct Pending: Codable, Equatable {
        var state: String
        var serverID: UUID
        var name: String
        var startedAt: Date
    }

    /// The daemon forgets a sign-in after ten minutes; so does the app.
    static let lifetime: TimeInterval = 10 * 60
    static let storeKey = "oauth.pending.v1"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let opener: @MainActor (URL) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var authorizeURL: URL?
    /// What to start again for "Try again", and the server to tell when the owner gives up.
    @ObservationIgnored private var attempt: (server: any OAuthServer, target: OAuthBeginTarget, name: String)?
    /// Changes with each start and each cancel, so an answer that arrives late knows it is out of date.
    @ObservationIgnored private var run = UUID()

    public init(
        defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
        opener: @escaping @MainActor (URL) -> Void = OAuthSignIn.openInBrowser
    ) {
        self.defaults = defaults
        self.now = now
        self.opener = opener
        pending = Self.load(defaults)
    }

    /// Whether a sheet should be on screen.
    public var isActive: Bool { phase != .idle }

    public static func openInBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - start

    /// Starts a sign-in: asks the server for the address and opens it. A sign-in that was waiting is dropped first.
    public func begin(server: any OAuthServer, target: OAuthBeginTarget, name: String) async {
        await discard()
        let id = UUID()
        run = id
        attempt = (server, target, name)
        phase = .starting(name: name)
        do {
            let begun = try await server.oauthBegin(target)
            guard run == id else {
                // Cancelled while the server was answering.
                await server.oauthCancel(state: begun.state)
                return
            }
            guard let url = Self.browserURL(begun.authorizeUrl) else {
                await server.oauthCancel(state: begun.state)
                phase = .failed(name: name, message: Self.failure(nil), canRetry: true)
                return
            }
            let record = Pending(state: begun.state, serverID: server.oauthServerID, name: name, startedAt: now())
            remember(record)
            authorizeURL = url
            phase = .waiting(name: name)
            opener(url)
        } catch {
            guard run == id else { return }
            phase = .failed(name: name, message: Self.failure(error), canRetry: true)
        }
    }

    /// Opens the same address again, for an owner who closed the tab.
    public func reopenBrowser() {
        guard case .waiting = phase, let authorizeURL else { return }
        opener(authorizeURL)
    }

    /// "Try again" after a failure: the same sign-in from the start.
    public func retry() async {
        guard case .failed = phase, let attempt else { return }
        await begin(server: attempt.server, target: attempt.target, name: attempt.name)
    }

    // MARK: - end

    /// The owner closes the sheet: a sign-in in progress is given up (the server is told), anything else just goes.
    public func dismiss() async {
        switch phase {
        case .starting, .waiting:
            await discard()
        case .finishing:
            // The code is with the server already; the sheet closes when it answers.
            return
        default:
            break
        }
        phase = .idle
    }

    /// Gives up a sign-in that is starting or waiting. The server is told so the state is spent at once.
    private func discard() async {
        run = UUID()
        let record = pending
        forget()
        authorizeURL = nil
        if case .waiting = phase { phase = .idle }
        if case .starting = phase { phase = .idle }
        if let record, let server = attempt?.server, server.oauthServerID == record.serverID {
            await server.oauthCancel(state: record.state)
        }
    }

    // MARK: - the way back

    /// Takes a `bandito://oauth/callback` address. Returns the server it belongs to, or nil when the app did nothing
    /// with it: `url` is not a callback, or it is not the answer to the sign-in the app waits for. Any web page can
    /// open `bandito://oauth/callback?state=x`, so a callback with another state (or with no sign-in pending, or the
    /// echo of one that was handed over already) is dropped without a word: no sheet, no navigation, the pending
    /// sign-in untouched.
    @discardableResult
    public func handle(_ url: URL, server lookup: (UUID) -> (any OAuthServer)?) async -> UUID? {
        guard let callback = OAuthCallback.parse(url) else { return nil }
        guard let record = pending, let state = callback.state, state == record.state else { return nil }
        guard now().timeIntervalSince(record.startedAt) <= Self.lifetime else {
            // The right state, too late: the daemon has forgotten it, the owner starts again.
            forget()
            phase = .failed(name: record.name, message: Self.lost, canRetry: false)
            return record.serverID
        }
        guard let server = lookup(record.serverID) else {
            forget()
            phase = .failed(name: record.name, message: Self.lost, canRetry: false)
            return record.serverID
        }
        let name = record.name
        guard callback.error == nil, let code = callback.code else {
            // "access_denied", or no code: the owner said no in the browser.
            forget()
            await server.oauthCancel(state: record.state)
            phase = .failed(
                name: name, message: UserFacingMessage(text: L10n.Integrations.Oauth.denied(name: name)), canRetry: true)
            return record.serverID
        }
        // The state is spent from here on, whatever the server answers.
        forget()
        authorizeURL = nil
        run = UUID()
        phase = .finishing(name: name)
        do {
            let done = try await server.oauthComplete(state: record.state, code: code, iss: callback.iss)
            // The name the person saw while signing in (the template's), not the integration's id-like name.
            phase = .connected(name: name, integrationID: done.id)
        } catch {
            phase = .failed(name: name, message: Self.failure(error), canRetry: true)
        }
        return record.serverID
    }

    // MARK: - pieces

    private func remember(_ record: Pending) {
        pending = record
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.storeKey) }
    }

    private func forget() {
        pending = nil
        defaults.removeObject(forKey: Self.storeKey)
    }

    private static func load(_ defaults: UserDefaults) -> Pending? {
        guard let data = defaults.data(forKey: storeKey) else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    /// The address to open: https (plain http only for this Mac), nothing else, so a bad answer cannot make the
    /// app open a file or another program.
    static func browserURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host,
            !host.isEmpty
        else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) { return url }
        return nil
    }

    private static let lost = UserFacingMessage(text: L10n.Integrations.Oauth.lost)

    /// A failure in words: what the daemon said goes under "Подробнее", the sentence is ours.
    private static func failure(_ error: Error?) -> UserFacingMessage {
        guard let error else { return UserFacingMessage(text: L10n.Integrations.Oauth.failed) }
        let message = UserFacingError.message(for: error)
        // A known failure (no answer from the server, a revoked device) keeps its own words; anything else gets ours,
        // with what the daemon said under the details.
        guard message.technical != nil else { return message }
        return UserFacingMessage(text: L10n.Integrations.Oauth.failed, technical: message.technical, canRetry: true)
    }
}
