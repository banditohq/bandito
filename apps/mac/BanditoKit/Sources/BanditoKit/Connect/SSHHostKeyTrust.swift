import Foundation

/// The host key the person looked at before trusting the host.
public struct HostKeyPreview: Equatable, Sendable {
    /// The `ssh-keyscan` output: known_hosts lines, ready to append.
    public var scanOutput: String
    /// The SHA-256 fingerprint of the first key, as `ssh-keygen -lf` prints it (`SHA256:…`).
    public var fingerprint: String
}

public enum SSHHostKeyError: Error, Equatable, LocalizedError {
    /// The scan returned nothing usable.
    case noKey
    /// The key the server presents now is not the one that was shown: nothing is written.
    case changedSinceReview
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: return "The server did not present a host key."
        case .changedSinceReview: return "The host key changed while you were checking it. Nothing was trusted."
        case .io(let detail): return detail
        }
    }
}

/// Trust in a new host key, the way ssh's own `known_hosts` expects it. Every command is an executable and an
/// argument array (never a shell string), and the host comes only from `SSHTarget`, which rejects shell characters.
///
/// Two steps, both explicit: `preview` scans and shows the fingerprint; `trust` scans again, and writes the key
/// only when the fingerprint still matches what was shown.
public struct SSHHostKeyTrust: Sendable {
    public static let keyscanPath = "/usr/bin/ssh-keyscan"
    public static let keygenPath = "/usr/bin/ssh-keygen"
    public static var defaultKnownHosts: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh/known_hosts")
    }

    private let runner: CommandRunner
    private let knownHosts: URL

    /// - Parameters:
    ///   - runner: runs ssh-keyscan and ssh-keygen (tests pass a fake).
    ///   - knownHosts: the file the key is appended to. Default: `~/.ssh/known_hosts`.
    public init(runner: CommandRunner, knownHosts: URL = SSHHostKeyTrust.defaultKnownHosts) {
        self.runner = runner
        self.knownHosts = knownHosts
    }

    /// `ssh-keyscan -T 5 [-p PORT] HOST`. The host is the validated target host, never a user-typed string.
    public static func keyscanArguments(for target: SSHTarget) -> [String] {
        ["-T", "5"] + (target.port.map { ["-p", String($0)] } ?? []) + [target.host]
    }

    /// The fingerprint of the first key in `ssh-keygen -lf` output: `256 SHA256:abc… host (ED25519)`.
    public static func fingerprint(fromKeygen output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            if let token = line.split(separator: " ").first(where: { $0.hasPrefix("SHA256:") }) {
                return String(token)
            }
        }
        return nil
    }

    /// Scans the host and returns what to show: the fingerprint and the scan output.
    public func preview(_ target: SSHTarget) async throws -> HostKeyPreview {
        let scan = try await scanned(target)
        return HostKeyPreview(scanOutput: scan.output, fingerprint: scan.fingerprint)
    }

    /// Appends the reviewed key to the known_hosts file, if the server still presents that same key.
    public func trust(_ preview: HostKeyPreview, for target: SSHTarget) async throws {
        let fresh = try await scanned(target)
        guard fresh.fingerprint == preview.fingerprint else {
            throw SSHHostKeyError.changedSinceReview
        }
        do {
            try FileManager.default.createDirectory(
                at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
            var text = (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? ""
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += fresh.output
            try text.write(to: knownHosts, atomically: true, encoding: .utf8)
        } catch {
            throw SSHHostKeyError.io(error.localizedDescription)
        }
    }

    private func scanned(_ target: SSHTarget) async throws -> (output: String, fingerprint: String) {
        let scan = try await runner.run(Self.keyscanPath, Self.keyscanArguments(for: target), stdin: nil)
        guard scan.status == 0, !scan.stdout.isEmpty else { throw SSHHostKeyError.noKey }
        let keygen = try await runner.run(Self.keygenPath, ["-lf", "-"], stdin: Data(scan.stdout.utf8))
        guard let fingerprint = Self.fingerprint(fromKeygen: keygen.stdout) else { throw SSHHostKeyError.noKey }
        return (scan.stdout, fingerprint)
    }
}
