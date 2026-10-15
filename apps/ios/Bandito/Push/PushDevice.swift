import Foundation
import os

/// What the registrar needs of the phone's own registration with the cloud.
@MainActor
protocol PushHandleSource: AnyObject {
    /// The cloud address of this phone, once this launch has confirmed it (the Apple token arrived and the cloud knows it).
    var handle: String? { get }
    /// Registers with the cloud when the registration is missing, old or for another token. `force` asks the cloud again
    /// whatever the keychain says (the daemon lost the address).
    func ensureHandle(force: Bool) async
}

/// This phone's registration with the Bandito cloud: the Apple token in, the handle out, kept in the shared Keychain with
/// the token and the environment it was made for.
///
/// A handle is handed out only after this launch has confirmed it: a Keychain that outlived a reinstall holds the old
/// install's handle, which no push would reach.
@MainActor
final class PushDevice: PushHandleSource {
    private static let log = Logger(subsystem: "dev.bandito", category: "push")

    /// The cloud's answer is asked again after this long, so a handle the cloud forgot is replaced.
    static let refreshInterval: TimeInterval = 24 * 3600
    /// A failed attempt is not repeated sooner than this (the cloud allows 30 an hour per address).
    static let retryInterval: TimeInterval = 60

    private let keychain: PushKeychain
    private let cloud: PushCloud
    private let environment: () -> String
    private let now: () -> Date

    /// The Apple token of this launch, in hex.
    private(set) var token: String?
    /// The confirmed handle.
    private(set) var handle: String?
    /// Told when the confirmed handle changes (the servers are registered again with the new one).
    var onHandleChange: (@MainActor () -> Void)?

    private var running: Task<Void, Never>?
    private var lastAttempt: Date?

    init(
        keychain: PushKeychain = .shared, cloud: PushCloud = BanditoPushCloud(),
        environment: @escaping () -> String = { PushEnvironment.current() }, now: @escaping () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.cloud = cloud
        self.environment = environment
        self.now = now
    }

    /// The token Apple gave this launch. A new one (or the first) starts the registration.
    func tokenReceived(_ data: Data) async {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard !hex.isEmpty else { return }
        if token != hex {
            token = hex
            // A handle confirmed for the old token is no longer.
            if handle != nil, keychain.registration()?.token != hex { setHandle(nil) }
        }
        await ensureHandle(force: false)
    }

    func ensureHandle(force: Bool) async {
        // One registration at a time; a caller that finds one running waits for it.
        if let running {
            await running.value
            if !force { return }
        }
        let task = Task { @MainActor in await self.register(force: force) }
        running = task
        await task.value
        running = nil
    }

    private func register(force: Bool) async {
        guard let token else { return }
        let env = environment()
        let stored = keychain.registration()
        let matches = stored.map { $0.token == token && $0.env == env } ?? false
        if matches, let stored, !force {
            let age = now().timeIntervalSince(keychain.registeredAt ?? .distantPast)
            if age < Self.refreshInterval {
                setHandle(stored.handle)
                return
            }
        }
        if let last = lastAttempt, !force, now().timeIntervalSince(last) < Self.retryInterval {
            // Too soon after a failure; the stored handle stays in use when it is for this token.
            if matches, let stored { setHandle(stored.handle) }
            return
        }
        lastAttempt = now()
        do {
            let made = try await cloud.register(token: token, env: env)
            do {
                try keychain.save(PushRegistration(token: token, env: env, handle: made), at: now())
            } catch {
                // The push extension reads the handle from the Keychain: without it pushes show the cloud's own text.
                Self.log.error("the push handle could not be kept in the Keychain")
            }
            setHandle(made)
            if let old = stored?.handle, old != made {
                // The earlier install's or token's address: the cloud may drop it. Nobody needs to hear about a failure.
                try? await cloud.unregister(handle: old)
            }
        } catch PushCloudError.conflict {
            // The cloud holds this token for the other environment. The old address is dropped and nothing more is tried now.
            Self.log.error("push registration refused: the token is known in the other environment")
            if let old = stored?.handle { try? await cloud.unregister(handle: old) }
            keychain.clearRegistration()
            setHandle(nil)
        } catch {
            Self.log.error("push registration failed; it is tried again later")
            if matches, let stored { setHandle(stored.handle) }
        }
    }

    private func setHandle(_ new: String?) {
        guard handle != new else { return }
        handle = new
        onHandleChange?()
    }
}
