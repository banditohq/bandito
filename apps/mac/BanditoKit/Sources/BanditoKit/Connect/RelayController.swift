import Foundation
import Observation

/// What the controller needs from a server. `ServerModel` conforms; tests bring a fake.
@MainActor
public protocol RelayHost: AnyObject {
    var relayName: String { get }
    var supportsRelay: Bool { get }
    func relayStatus() async throws -> RelayStatus
    func relayEnable(url: String, sid: String, secret: String) async throws -> RelayStatus
    func relayDisable() async throws -> RelayStatus
}

extension ServerModel: RelayHost {
    public var relayName: String { info?.hostname ?? config.name }
}

/// Turns Bandito Relay on and off for one server: the registration at bandito.dev (through the signed-in account) and the
/// daemon's `relay.enable` / `relay.disable`, in an order that leaves nothing half-done. One at a time: a second tap while
/// a step runs does nothing.
@MainActor
@Observable
public final class RelayController {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Making the registration and handing it to the server.
        case enabling
        /// Waiting for the server to reach the relay.
        case connecting
        case disabling
    }

    public enum Problem: Sendable, Equatable {
        /// Nobody is signed in: the person is asked to sign in first.
        case needsSignIn
        /// The server's daemon is too old.
        case unsupported
        /// The account service refused or could not be reached.
        case account(Error)
        /// The daemon refused (or did not answer).
        case daemon(Error)
        /// Registered, but the server did not reach the relay in time. `reason` is the daemon's sentence, if any.
        case notConnected(reason: String?)

        public static func == (a: Problem, b: Problem) -> Bool {
            switch (a, b) {
            case (.needsSignIn, .needsSignIn), (.unsupported, .unsupported): return true
            case (.account(let x), .account(let y)), (.daemon(let x), .daemon(let y)):
                return String(describing: x) == String(describing: y)
            case (.notConnected(let x), .notConnected(let y)): return x == y
            default: return false
            }
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var status: RelayStatus?
    public private(set) var problem: Problem?
    /// Whether the status could be read at least once.
    public private(set) var loaded = false

    @ObservationIgnored private let host: RelayHost
    /// The registrar of the signed-in account; nil when nobody is signed in.
    @ObservationIgnored private let registrar: @Sendable () async throws -> RelayRegistrar?
    @ObservationIgnored private let connectTimeout: Duration
    @ObservationIgnored private let pollInterval: Duration

    public init(
        host: RelayHost, registrar: @escaping @Sendable () async throws -> RelayRegistrar?,
        connectTimeout: Duration = .seconds(20), pollInterval: Duration = .milliseconds(500)
    ) {
        self.host = host
        self.registrar = registrar
        self.connectTimeout = connectTimeout
        self.pollInterval = pollInterval
    }

    public var isBusy: Bool { phase != .idle }
    public var isOn: Bool { status?.enabled == true }
    public var isConnected: Bool { status?.enabled == true && status?.connected == true }

    /// Reads the server's status. A failure leaves the last one.
    public func refresh() async {
        guard host.supportsRelay else { return }
        if let fresh = try? await host.relayStatus() {
            status = fresh
            loaded = true
        }
    }

    /// Switches the cloud on, or takes the one that is on. Returns true when the server is connected to the relay.
    @discardableResult
    public func enable() async -> Bool {
        guard phase == .idle else { return false }
        problem = nil
        guard host.supportsRelay else {
            problem = .unsupported
            return false
        }
        phase = .enabling
        defer { phase = .idle }
        // Already on: nothing to register again.
        do {
            let current = try await host.relayStatus()
            status = current
            loaded = true
            if current.enabled {
                phase = .connecting
                return await waitForConnection()
            }
        } catch {
            problem = .daemon(error)
            return false
        }
        let account: RelayRegistrar
        do {
            guard let found = try await registrar() else {
                problem = .needsSignIn
                return false
            }
            account = found
        } catch {
            problem = .account(error)
            return false
        }
        let registration: RelayRegistration
        do {
            registration = try await account.registerRelayServer(name: host.relayName)
        } catch AccountError.notSignedIn {
            problem = .needsSignIn
            return false
        } catch {
            problem = .account(error)
            return false
        }
        do {
            status = try await host.relayEnable(url: registration.relayURL, sid: registration.sid, secret: registration.secret)
        } catch {
            // The daemon did not take it: the registration would only use up one of the account's ten places.
            await Self.removeRegistration(account, sid: registration.sid)
            problem = .daemon(error)
            return false
        }
        phase = .connecting
        return await waitForConnection()
    }

    /// Switches the cloud off: the server forgets it first, then the registration is deleted (when the account is there to
    /// do it; the registration of a signed-out Mac is removed the next time the person signs in and looks, or from the
    /// website — the server no longer connects with it either way).
    @discardableResult
    public func disable() async -> Bool {
        guard phase == .idle else { return false }
        problem = nil
        guard host.supportsRelay else { return false }
        phase = .disabling
        defer { phase = .idle }
        let sid = status?.sid
        do {
            status = try await host.relayDisable()
        } catch {
            problem = .daemon(error)
            return false
        }
        if let sid, let account = try? await registrar() {
            await Self.removeRegistration(account, sid: sid)
        }
        return true
    }

    /// Deletes a registration even if the caller was cancelled (the wizard was closed): in a task of its own.
    private static func removeRegistration(_ account: RelayRegistrar, sid: String) async {
        await Task { try? await account.deleteRelayServer(sid: sid) }.value
    }

    private func waitForConnection() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + connectTimeout
        while true {
            if let current = try? await host.relayStatus() { status = current }
            if status?.connected == true { return true }
            if status?.enabled != true { return false }
            if clock.now >= deadline { break }
            if (try? await Task.sleep(for: pollInterval)) == nil { return false }
        }
        problem = .notConnected(reason: status?.lastError)
        return false
    }
}
