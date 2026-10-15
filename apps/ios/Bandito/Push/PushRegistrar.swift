import BanditoKit
import CryptoKit
import Foundation
import os

/// A server as the registrar sees it. `ServerModel` is one; tests use a fake that records the calls.
@MainActor
protocol PushServerAPI: AnyObject {
    /// What the push calls the server: its id.
    var pushRef: String { get }
    var isConnected: Bool { get }
    /// The daemon has `"push"` in its features. An older one is left alone.
    var supportsPush: Bool { get }
    func pushRegister(handle: String, key: Data, serverRef: String, kinds: [String], lang: String?) async throws
    func pushUnregister() async throws
    func pushIsRegistered() async throws -> Bool
}

extension ServerModel: PushServerAPI {
    var pushRef: String { id.uuidString }
    var isConnected: Bool { state == .connected }
}

/// The notification kinds of the settings, as the daemon names them.
enum PushKinds {
    /// Approvals and questions are one switch in Settings ("needs you"); answers and errors have their own.
    static func kinds(approvals: Bool, answers: Bool, errors: Bool) -> [String] {
        var kinds: [String] = []
        if approvals { kinds += ["approval", "question"] }
        if answers { kinds.append("done") }
        if errors { kinds.append("error") }
        return kinds
    }

    /// The language code the daemon takes (letters, digits, `-`, `_`, at most 16): the phone's first language.
    static func language(from preferred: String?) -> String? {
        guard let preferred else { return nil }
        let clean = String(preferred.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(16))
        return clean.isEmpty ? nil : clean
    }
}

/// Tells each connected server where to send this phone's push notifications (`push.register`), and takes it back when
/// the person turns notifications off or forgets the server.
///
/// What the last registration said (the handle, the kinds, the language) is remembered per server, so a connection that
/// comes back changes nothing; a change of any of them, or a day, registers again. A server that connects is asked
/// `push.status` once: the daemon forgets an address the cloud refused, and the phone then registers again.
@MainActor
final class PushRegistrar {
    private static let log = Logger(subsystem: "dev.bandito", category: "push")

    static let refreshInterval: TimeInterval = 24 * 3600
    static let stateKeyPrefix = "push.reg."
    /// What is stored while a server has been told to stop.
    static let offMark = "off"

    private let keychain: PushKeychain
    private let device: PushHandleSource
    private let servers: () -> [any PushServerAPI]
    private let isLoaded: () -> Bool
    private let allowed: () -> Bool
    private let kinds: () -> [String]
    private let language: () -> String?
    private let defaults: UserDefaults
    private let shared: PushShared
    private let now: () -> Date
    /// How long to wait before the next try after `attempt` failures in a row; nil: no retry (tests).
    private let retryDelay: (Int) -> Duration?
    /// Servers whose keys are kept though they are not in the list (the debug key of `-push-test-key`).
    private let keepRefs: Set<String>

    private var connected: Set<String> = []
    private var busy = false
    private var pending = false
    private var retry: Task<Void, Never>?
    /// Failures in a row (a missing handle, a refused registration): the pause grows with it. Reset by a pass with none.
    private(set) var failures = 0
    private var failedThisPass = false
    /// A retry is waiting (tests read it).
    var isRetryScheduled: Bool { retry != nil }

    /// Tests only: drops a waiting retry.
    func cancelRetryForTests() {
        retry?.cancel()
        retry = nil
    }

    /// 30 seconds, 2 minutes, 10 minutes, then once an hour.
    nonisolated static func backoff(attempt: Int) -> Duration? {
        switch attempt {
        case ...1: .seconds(30)
        case 2: .seconds(120)
        case 3: .seconds(600)
        default: .seconds(3600)
        }
    }

    init(
        keychain: PushKeychain, device: PushHandleSource, servers: @escaping () -> [any PushServerAPI],
        isLoaded: @escaping () -> Bool, allowed: @escaping () -> Bool, kinds: @escaping () -> [String],
        language: @escaping () -> String?, defaults: UserDefaults = .standard, shared: PushShared = .shared,
        now: @escaping () -> Date = { Date() }, retryDelay: @escaping (Int) -> Duration? = PushRegistrar.backoff, keepRefs: Set<String> = []
    ) {
        self.keychain = keychain
        self.device = device
        self.servers = servers
        self.isLoaded = isLoaded
        self.allowed = allowed
        self.kinds = kinds
        self.language = language
        self.defaults = defaults
        self.shared = shared
        self.now = now
        self.retryDelay = retryDelay
        self.keepRefs = keepRefs
    }

    /// Looks at everything again and does what is missing. Calls that arrive while it runs are folded into one more pass.
    func reconcile() async {
        pending = true
        guard !busy else { return }
        busy = true
        defer { busy = false }
        while pending {
            pending = false
            await pass()
        }
    }

    /// Asks for a pass without waiting for it.
    func requestReconcile() {
        Task { await reconcile() }
    }

    private func pass() async {
        failedThisPass = false
        defer {
            if failedThisPass { scheduleRetry() } else {
                failures = 0
                retry?.cancel()
                retry = nil
            }
        }
        let all = servers()
        if isLoaded() { prune(keeping: Set(all.map(\.pushRef)).union(keepRefs)) }
        let wanted = kinds()
        let enabled = allowed() && !wanted.isEmpty
        let eligible = all.filter { $0.isConnected && $0.supportsPush }
        var handle = device.handle
        if enabled, handle == nil, !eligible.isEmpty {
            await device.ensureHandle(force: false)
            handle = device.handle
            // The cloud could not be reached (or refused): tried again, later and later.
            if handle == nil { failedThisPass = true }
        }
        var nowConnected: Set<String> = []
        var allCurrent = true
        for server in eligible {
            // The connection may have dropped while an earlier server was being told.
            guard server.isConnected else { continue }
            let fresh = !connected.contains(server.pushRef)
            nowConnected.insert(server.pushRef)
            if enabled {
                guard let handle else {
                    allCurrent = false
                    continue
                }
                await register(server, handle: handle, kinds: wanted, fresh: fresh)
                if lastFingerprint(of: server.pushRef) == nil || !isCurrent(server, handle: handle, kinds: wanted) {
                    allCurrent = false
                }
            } else {
                await switchOff(server)
            }
        }
        connected = nowConnected
        // A server that is out of reach and was registered with an earlier handle still sends with it: the old handle waits.
        for server in all where !eligible.contains(where: { $0.pushRef == server.pushRef }) {
            if let handle, let state = stored(server.pushRef), state.fingerprint != Self.offMark,
                !isCurrent(server, handle: handle, kinds: wanted)
            {
                allCurrent = false
            }
        }
        // The handle that was replaced is let go once every server that gets push knows the new one.
        if enabled, allCurrent, !eligible.isEmpty, let handle, keychain.registration()?.handle == handle {
            keychain.clearPreviousHandle()
        }
    }

    /// Whether the server's last registration was made with this handle, these kinds, this language and the key it has now.
    private func isCurrent(_ server: any PushServerAPI, handle: String, kinds: [String]) -> Bool {
        guard let key = keychain.key(for: server.pushRef) else { return false }
        return stored(server.pushRef)?.fingerprint
            == Self.fingerprint(handle: handle, kinds: kinds, lang: language(), key: key)
    }

    private func register(_ server: any PushServerAPI, handle first: String, kinds: [String], fresh: Bool) async {
        let ref = server.pushRef
        let key: SymmetricKey
        do {
            key = try keychain.keyCreating(for: ref)
        } catch {
            Self.log.error("the key of a server could not be kept; push is not registered for it")
            failedThisPass = true
            return
        }
        var handle = first
        let lang = language()
        let last = stored(ref)
        var needs = last == nil || last?.fingerprint != Self.fingerprint(handle: handle, kinds: kinds, lang: lang, key: key)
            || now().timeIntervalSince(last?.at ?? .distantPast) >= Self.refreshInterval
        if !needs, fresh, let registered = try? await server.pushIsRegistered(), !registered {
            // The daemon let this phone's address go (the cloud said it is unknown): the cloud is asked again, then the daemon.
            await device.ensureHandle(force: true)
            if let renewed = device.handle { handle = renewed }
            needs = true
        }
        guard needs else { return }
        let fingerprint = Self.fingerprint(handle: handle, kinds: kinds, lang: lang, key: key)
        do {
            try await server.pushRegister(
                handle: handle, key: key.withUnsafeBytes { Data($0) }, serverRef: ref, kinds: kinds, lang: lang)
            remember(ref, fingerprint)
        } catch {
            Self.log.error("push.register failed; it is tried again")
            failedThisPass = true
        }
    }

    private func switchOff(_ server: any PushServerAPI) async {
        let ref = server.pushRef
        if stored(ref)?.fingerprint == Self.offMark { return }
        do {
            try await server.pushUnregister()
            remember(ref, Self.offMark)
        } catch {
            Self.log.error("push.unregister failed; it is tried again")
            failedThisPass = true
        }
    }

    /// A server was removed from this phone. Its key goes, and, when it can be reached (`unregister`), it is told to stop
    /// (a server the device is revoked on forgets the registration with it).
    func forgotten(_ server: any PushServerAPI, unregister: Bool) async {
        if unregister, server.isConnected {
            // A server that does not answer must not hold the removal: five seconds at most.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(continuation)
                Task { @MainActor in
                    try? await server.pushUnregister()
                    once.resume()
                }
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    once.resume()
                }
            }
        }
        forget(ref: server.pushRef)
        connected.remove(server.pushRef)
    }

    private func forget(ref: String) {
        keychain.deleteKey(for: ref)
        defaults.removeObject(forKey: Self.stateKeyPrefix + ref)
        shared.forgetSeq(for: ref)
    }

    /// Keys of servers that are not in the list any more (a reinstall keeps the Keychain, and a server may be removed while
    /// the phone is off): nobody could use them.
    private func prune(keeping refs: Set<String>) {
        for ref in keychain.serverRefs() where !refs.contains(ref) { forget(ref: ref) }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        failures += 1
        guard let delay = retryDelay(failures) else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            await self.reconcile()
        }
    }

    // MARK: what was told

    /// A hash of what a registration said: the handle, the kinds (in any order), the language, and which key it carried
    /// (the first 8 bytes of the key's SHA-256, so a key made anew is told to the daemon).
    static func fingerprint(handle: String, kinds: [String], lang: String?, key: SymmetricKey) -> String {
        let keyID = SHA256.hash(data: key.withUnsafeBytes { Data($0) }).prefix(8).map { String(format: "%02x", $0) }.joined()
        let text = [handle, kinds.sorted().joined(separator: ","), lang ?? "", keyID].joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Stored {
        var fingerprint: String
        var at: Date
    }

    private func stored(_ ref: String) -> Stored? {
        guard let text = defaults.string(forKey: Self.stateKeyPrefix + ref) else { return nil }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let seconds = TimeInterval(parts[1]) else { return nil }
        return Stored(fingerprint: String(parts[0]), at: Date(timeIntervalSince1970: seconds))
    }

    private func remember(_ ref: String, _ fingerprint: String) {
        defaults.set("\(fingerprint)|\(now().timeIntervalSince1970)", forKey: Self.stateKeyPrefix + ref)
    }

    /// What was last told about a server: its fingerprint (tests read it).
    func lastFingerprint(of ref: String) -> String? { stored(ref)?.fingerprint }
}

/// Resumes a continuation once, from whichever of two tasks comes first.
private final class ResumeOnce: @unchecked Sendable {
    // @unchecked: `continuation` is taken under `lock`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let taken = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        taken?.resume()
    }
}
