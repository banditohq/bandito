import Foundation
#if os(macOS)
import Network
#endif

/// Why an ssh connection could not be made or kept.
public enum SSHTunnelError: Error, Sendable, Equatable, LocalizedError {
    /// The address is not usable as an ssh target.
    case invalidTarget
    /// The server did not accept this Mac's key (`Permission denied`).
    case authFailed
    /// The host name does not resolve.
    case unknownHost
    /// The host key is new or changed (`Host key verification failed`).
    case hostKeyChanged
    /// No answer: timeout, refused, no route.
    case unreachable
    /// ssh stopped with a message this list does not name. `detail` is its last line.
    case exited(detail: String)
    /// Another program holds every local port this tunnel tried. Nothing was sent through the tunnel.
    case portHijacked

    /// Maps ssh's own messages to a case. Nil for anything else. Only meaningful for stderr of an ssh process
    /// that exited with status 255, which is what ssh uses for its own failures.
    public static func classify(stderr: String) -> SSHTunnelError? {
        if stderr.contains("Permission denied") { return .authFailed }
        if stderr.contains("Could not resolve hostname") { return .unknownHost }
        if stderr.contains("Host key verification failed") || stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return .hostKeyChanged
        }
        let unreachableMarkers = [
            "Connection timed out", "Operation timed out", "Connection refused", "No route to host",
            "Network is unreachable",
        ]
        if unreachableMarkers.contains(where: stderr.contains) { return .unreachable }
        return nil
    }

    /// The error for a failed ssh process, from its stderr.
    static func from(stderr: String) -> SSHTunnelError {
        classify(stderr: stderr) ?? .exited(detail: lastLine(of: stderr))
    }

    /// Permanent errors are not retried: the same call will fail the same way.
    public var isPermanent: Bool {
        switch self {
        case .invalidTarget, .authFailed, .unknownHost, .hostKeyChanged, .portHijacked: return true
        case .unreachable, .exited: return false
        }
    }

    /// The last non-empty line of ssh's output, trimmed. Empty when there is none.
    static func lastLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
    }

    public var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "That is not a valid SSH address. Use an alias, or user@host:port."
        case .authFailed:
            return "The server did not accept this Mac's SSH key. Check ~/.ssh/config and your keys."
        case .unknownHost:
            return "The host name does not resolve. Check the address."
        case .hostKeyChanged:
            return "The server's SSH host key is new or has changed. Connect once in Terminal to check it."
        case .unreachable:
            return "The server did not answer. Check the address and that it is online."
        case .exited(let detail):
            return detail.isEmpty ? "ssh stopped unexpectedly." : "ssh stopped: \(detail)"
        case .portHijacked:
            return "A local port for the SSH tunnel is held by another program. Nothing was sent to the server."
        }
    }
}

#if os(macOS)

/// The pids with a listening TCP socket on a port. Injected so tests can say who holds a port.
public typealias ListenerLookup = @Sendable (_ port: Int) async throws -> Set<Int32>

/// An `ssh -N -L` process that carries one local port to the daemon's loopback port on a server.
///
/// `start()` picks a free local port and waits until it accepts connections (up to 15 s). If ssh exits
/// later, the tunnel restarts it with backoff (`restartDelays`), on the same local port, so `localURL`
/// does not change. A permanent error (`SSHTunnelError.isPermanent`) stops the retries.
public actor SSHTunnel {
    public static let sshPath = "/usr/bin/ssh"
    public static let readyTimeout: Duration = .seconds(15)
    /// Waits before restart 1, 2, 3, …; the last value repeats.
    public static let restartDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]
    /// Local ports tried before `portHijacked`.
    public static let maxPortAttempts = 3
    static let lsofPath = "/usr/sbin/lsof"

    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case up
        /// ssh exited; the tunnel will try again. `attempt` counts from 1.
        case restarting(attempt: Int)
        case failed(SSHTunnelError)
    }

    public private(set) var state: State = .stopped
    /// The local port, once started. Kept across restarts.
    public private(set) var localPort: Int?

    /// `ws://127.0.0.1:<port>/v1/rpc`: where the daemon's WebSocket answers through this tunnel.
    public var localURL: URL? {
        localPort.flatMap { URL(string: "ws://127.0.0.1:\($0)/v1/rpc") }
    }

    private let target: SSHTarget
    private let remotePort: Int
    private let sshPath: String
    private let listeners: ListenerLookup
    private var process: Process?
    private var pipe: Pipe?
    private var stderr: StderrBuffer?
    /// Bumped by every launch and by `stop()`. An exit of an older process is ignored.
    private var generation = 0
    private var exitSink: AsyncStream<Int>.Continuation?
    private var supervisor: Task<Void, Never>?

    /// - Parameters:
    ///   - target: `[user@]host[:port]` or an alias, as `SSHTarget.parse` reads it.
    ///   - remotePort: the port on the server's loopback that the tunnel reaches (the daemon's listen port).
    ///   - listeners: who listens on a local port. The tunnel is ready only when that is its own ssh.
    public init(
        target: String, remotePort: Int, sshPath: String = SSHTunnel.sshPath,
        listeners: @escaping ListenerLookup = SSHTunnel.listeningProcesses
    ) throws {
        guard let parsed = SSHTarget.parse(target) else { throw SSHTunnelError.invalidTarget }
        self.target = parsed
        self.remotePort = remotePort
        self.sshPath = sshPath
        self.listeners = listeners
    }

    /// Opens the tunnel. Throws the reason when ssh exits or the port stays closed.
    /// A call while the tunnel is already starting or running returns at once.
    ///
    /// Ready means: the ssh process is alive, the port accepts connections, and the only process listening on
    /// that port is this ssh. Callers send tokens and codes only after this returns.
    public func start() async throws {
        switch state {
        case .starting, .up, .restarting: return
        case .stopped, .failed: break
        }
        state = .starting
        let (exits, sink) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .unbounded)
        exitSink = sink
        do {
            let launched = try await establish()
            guard launched == generation else { throw SSHTunnelError.exited(detail: "stopped while starting") }
        } catch {
            let reason = error as? SSHTunnelError ?? .exited(detail: error.localizedDescription)
            state = .failed(reason)
            sink.finish()
            throw reason
        }
        state = .up
        supervisor = Task { await self.supervise(exits) }
    }

    /// Closes the tunnel and stops ssh. No restart follows.
    public func stop() {
        generation += 1
        state = .stopped
        supervisor?.cancel()
        supervisor = nil
        exitSink?.finish()
        exitSink = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
        }
        process = nil
        pipe = nil
        stderr = nil
        localPort = nil
    }

    /// The ssh arguments that forward `localPort` on this Mac to `remotePort` on the target's loopback.
    public static func arguments(target: SSHTarget, localPort: Int, remotePort: Int) -> [String] {
        [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)",
        ] + target.sshArguments
    }

    /// The wait before restart `attempt` (from 1). After the table, the last delay repeats.
    public static func delay(forRestart attempt: Int) -> Duration {
        restartDelays[min(max(attempt, 1), restartDelays.count) - 1]
    }

    /// See `SSHTunnelError.classify(stderr:)`.
    public static func classify(stderr: String) -> SSHTunnelError? {
        SSHTunnelError.classify(stderr: stderr)
    }

    /// Whether something accepts connections on `127.0.0.1:port`.
    public static func isAccepting(port: Int) async -> Bool {
        guard (1...65_535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run {
                        continuation.resume(returning: true)
                        connection.cancel()
                    }
                case .failed, .waiting, .cancelled:
                    once.run {
                        continuation.resume(returning: false)
                        connection.cancel()
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }

    // MARK: internals

    /// Starts ssh on a free local port. A port that another program holds (or an ssh that died binding it)
    /// is replaced by a new free port, up to `maxPortAttempts` times, then `portHijacked`.
    private func establish() async throws -> Int {
        for _ in 0..<Self.maxPortAttempts {
            let port = try Self.freeLocalPort()
            localPort = port
            do {
                return try await launch(port: port)
            } catch LaunchFailure.portTaken {
                continue
            }
        }
        throw SSHTunnelError.portHijacked
    }

    /// Starts one ssh process and waits until its port belongs to it. Returns the generation of the process.
    /// Throws `LaunchFailure.portTaken` when the port is held by another program.
    private func launch(port: Int) async throws -> Int {
        let buffer = StderrBuffer()
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = Self.arguments(target: target, localPort: port, remotePort: remotePort)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(chunk)
            }
        }
        generation += 1
        let current = generation
        process.terminationHandler = { [weak self] _ in
            Task { await self?.processEnded(current) }
        }
        self.process = process
        self.pipe = pipe
        self.stderr = buffer
        do {
            try process.run()
        } catch {
            throw SSHTunnelError.exited(detail: "could not start ssh (\(error.localizedDescription))")
        }

        let deadline = ContinuousClock.now.advanced(by: Self.readyTimeout)
        while true {
            if !process.isRunning {
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append((try? pipe.fileHandleForReading.readToEnd()) ?? Data())
                // A bind failure is a port takeover only when lsof names another listener on the port.
                // Otherwise it is an ordinary start failure, reported with ssh's own words.
                if Self.isPortConflict(stderr: buffer.text), await foreignListener(port: port, except: process.processIdentifier) {
                    throw LaunchFailure.portTaken
                }
                throw SSHTunnelError.from(stderr: buffer.text)
            }
            if await Self.isAccepting(port: port) {
                // Something accepts on the port. It is ours only if the listening process is this ssh.
                let owners: Set<Int32>
                do {
                    owners = try await listeners(port)
                } catch {
                    abandon(process, pipe: pipe)
                    throw error
                }
                if owners == [process.processIdentifier] { return current }
                abandon(process, pipe: pipe)
                // Another listener is named: the port was taken. No listener named: the owner is unknown, which
                // is an error, not a takeover.
                if owners.contains(where: { $0 != process.processIdentifier }) { throw LaunchFailure.portTaken }
                throw SSHTunnelError.exited(detail: "could not confirm which process listens on the tunnel port")
            }
            if ContinuousClock.now >= deadline {
                // Not an exit to react to: the launch is failing and the caller decides.
                generation += 1
                process.terminate()
                throw SSHTunnelError.unreachable
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Stops an ssh this tunnel will not use. Its exit no longer counts as a tunnel exit.
    private func abandon(_ process: Process, pipe: Pipe) {
        generation += 1
        process.terminationHandler = nil
        pipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func processEnded(_ ended: Int) {
        guard ended == generation else { return }
        exitSink?.yield(ended)
    }

    /// Restarts ssh whenever the current process ends, until it is up again or a permanent error comes.
    private func supervise(_ exits: AsyncStream<Int>) async {
        var attempt = 0
        for await ended in exits {
            guard ended == generation, let port = localPort else { continue }
            let reason = SSHTunnelError.from(stderr: stderr?.text ?? "")
            if reason.isPermanent {
                state = .failed(reason)
                return
            }
            var relaunched = false
            while !relaunched {
                attempt += 1
                state = .restarting(attempt: attempt)
                try? await Task.sleep(for: Self.delay(forRestart: attempt))
                if Task.isCancelled { return }
                do {
                    let launched = try await launch(port: port)
                    guard launched == generation, !Task.isCancelled else { return }
                    state = .up
                    attempt = 0
                    relaunched = true
                } catch let error as SSHTunnelError {
                    if error.isPermanent {
                        state = .failed(error)
                        return
                    }
                } catch LaunchFailure.portTaken {
                    // The port changed hands while the tunnel was down. Its URL cannot move, so stop here.
                    state = .failed(.portHijacked)
                    return
                } catch {
                    state = .failed(.exited(detail: error.localizedDescription))
                    return
                }
            }
        }
    }

    /// Whether lsof names a listener on `port` other than `pid`. Any lookup failure answers false.
    private func foreignListener(port: Int, except pid: Int32) async -> Bool {
        guard let owners = try? await listeners(port) else { return false }
        return owners.contains { $0 != pid }
    }

    /// ssh's words for "the local port is taken". With `ExitOnForwardFailure` ssh exits with them.
    static func isPortConflict(stderr: String) -> Bool {
        ["Address already in use", "cannot listen to port", "Could not request local forwarding"]
            .contains { stderr.contains($0) }
    }

    /// The pids with a listening TCP socket on `port`, from `lsof`. Status 1 means none; other failures throw.
    public static func listeningProcesses(port: Int) async throws -> Set<Int32> {
        let result = try await ProcessCommandRunner().run(
            lsofPath, ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"], stdin: nil)
        guard result.status == 0 || result.status == 1 else {
            throw SSHTunnelError.exited(detail: "could not check which process holds the port")
        }
        return Set(
            result.stdout.split(separator: "\n").compactMap { line -> Int32? in
                guard line.hasPrefix("p") else { return nil }
                return Int32(line.dropFirst())
            })
    }

    /// A free TCP port on 127.0.0.1, found by binding port 0 and reading back what the system chose.
    static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SSHTunnelError.exited(detail: "no socket for a local port") }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindStatus = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0 else { throw SSHTunnelError.exited(detail: "no free local port") }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameStatus == 0 else { throw SSHTunnelError.exited(detail: "no free local port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// A launch that did not get its port: another program holds it, or ssh could not bind it.
private enum LaunchFailure: Error {
    case portTaken
}

/// Collects a process's stderr from its readability handler, which runs on another thread.
// @unchecked: `data` is guarded by `lock`.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

#endif
