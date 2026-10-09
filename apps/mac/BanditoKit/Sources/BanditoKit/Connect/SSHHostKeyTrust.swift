import Foundation

/// The host key the person looked at before trusting the host: one key type, its SHA-256 fingerprint, and the
/// known_hosts lines that trusting it writes.
public struct HostKeyPreview: Equatable, Sendable {
    /// The type that was scanned: `ed25519`, `ecdsa` or `rsa`.
    public var keyType: String
    /// The SHA-256 fingerprint of that key, as `ssh-keygen -lf` prints it (`SHA256:…`).
    public var fingerprint: String
    /// The scan exactly as the server presented it.
    public var scanOutput: String
    /// The lines written on trust: the shown key, under the name the ssh client looks up (see `knownHostsField`).
    public var knownHostsLines: [String]
}

public enum SSHHostKeyError: Error, Equatable, LocalizedError {
    /// The scan returned no key of any type.
    case noKey
    /// The address goes through a jump host or a command (`ProxyJump`, `ProxyCommand`): the key cannot be
    /// reviewed from here. The person connects once in Terminal instead.
    case viaProxy
    /// The key the server presents changed between the review and the write: nothing is written.
    case changedBetweenChecks
    /// known_hosts already has this host with another key of the same type. Nothing is added; the person removes
    /// the old entry first (`ssh-keygen -R <host>`). `host` is the name the entry is kept under.
    case keyChangedSincePreviousVisit(host: String)
    /// The existing known_hosts file could not be read: nothing is written.
    case readFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: return "The server did not present a host key."
        case .viaProxy: return "This server is reached through a jump host. Connect once in Terminal to trust it."
        case .changedBetweenChecks: return "The server's host key changed between the two checks. Nothing was trusted."
        case .readFailed(let file): return "Could not read \(file). Nothing was changed."
        case .writeFailed(let file): return "Could not write \(file). Nothing was changed."
        case .keyChangedSincePreviousVisit(let host): return "The key for \(host) changed since last time. Nothing was trusted."
        }
    }
}

/// Trust in a new host key, the way ssh's own `known_hosts` expects it.
///
/// Every command is an executable with an argument array (never a shell string), and the target comes from
/// `SSHTarget`, which rejects shell characters. Steps, all explicit:
/// 1. `ssh -G` (no connection) gives the real host, port, host key alias, and whether a jump host is set.
/// 2. `preview` scans one key type at a time (ed25519, then ecdsa, then rsa) and shows its fingerprint.
/// 3. `trust` scans again, and writes the reviewed lines only when the second scan has the same keys.
public struct SSHHostKeyTrust: Sendable {
    public static let keyscanPath = "/usr/bin/ssh-keyscan"
    public static let keygenPath = "/usr/bin/ssh-keygen"
    public static let keyTypes = ["ed25519", "ecdsa", "rsa"]
    public static var defaultKnownHosts: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh/known_hosts")
    }

    /// Where ssh really connects for an address, and how its key is recorded.
    struct Endpoint: Equatable, Sendable {
        var host: String
        var port: Int
        var hostKeyAlias: String?
        var viaProxy: Bool
        /// The first file of `UserKnownHostsFile` from `ssh -G`, with `~` expanded. Trust writes there.
        var knownHostsPath: String?

        /// The first field of a known_hosts line: the alias when one is set, else `host` or `[host]:port`.
        var knownHostsField: String {
            if let hostKeyAlias { return hostKeyAlias }
            return port == 22 ? host : "[\(host)]:\(port)"
        }
    }

    private let runner: CommandRunner
    private let knownHosts: URL

    /// - Parameters:
    ///   - runner: runs ssh, ssh-keyscan and ssh-keygen (tests pass a fake).
    ///   - knownHosts: the file the key is added to. Default: `~/.ssh/known_hosts`.
    public init(runner: CommandRunner, knownHosts: URL = SSHHostKeyTrust.defaultKnownHosts) {
        self.runner = runner
        self.knownHosts = knownHosts
    }

    /// `ssh -G [-p PORT] DESTINATION`: prints the configuration without connecting.
    public static func configArguments(for target: SSHTarget) -> [String] {
        ["-G"] + target.sshArguments
    }

    /// `ssh-keyscan -T 5 -t TYPE -p PORT HOST`, from the resolved endpoint.
    static func keyscanArguments(host: String, port: Int, keyType: String) -> [String] {
        ["-T", "5", "-t", keyType, "-p", String(port), host]
    }

    /// Reads the keys of `ssh -G` output: `hostname`, `port`, `hostkeyalias`, `proxyjump`, `proxycommand`.
    static func endpoint(fromConfig output: String, target: SSHTarget) -> Endpoint {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        func set(_ key: String) -> String? {
            guard let value = values[key], !value.isEmpty, value != "none" else { return nil }
            return value
        }
        let host = set("hostname") ?? target.host
        let port = Int(values["port"] ?? "") ?? target.port ?? 22
        let knownHostsPath = set("userknownhostsfile")
            .flatMap { $0.split(separator: " ").first.map(String.init) }
            .map(expandTilde)
        return Endpoint(
            host: host, port: port, hostKeyAlias: set("hostkeyalias"),
            viaProxy: set("proxyjump") != nil || set("proxycommand") != nil,
            knownHostsPath: knownHostsPath)
    }

    static func expandTilde(_ path: String) -> String {
        path.hasPrefix("~/") ? NSHomeDirectory() + String(path.dropFirst(1)) : path
    }

    /// `ssh-keygen -F HOST -f FILE`: the entries of `host` in `file`.
    static func lookupArguments(host: String, file: String) -> [String] {
        ["-F", host, "-f", file]
    }

    /// The key parts (`type base64`) of the entries in `ssh-keygen -F` output. Comments are skipped.
    static func previousKeys(fromLookup output: String) -> [(type: String, key: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: " ")
            guard fields.count >= 3 else { return nil }
            return (String(fields[1]), String(fields[2]))
        }
    }

    /// Whether known_hosts holds this host with a key of the same type as one shown, but another key.
    static func conflicts(previous: [(type: String, key: String)], shown: [String]) -> Bool {
        let shownKeys = shown.compactMap { line -> (type: String, key: String)? in
            let fields = line.split(separator: " ")
            guard fields.count >= 3 else { return nil }
            return (String(fields[1]), String(fields[2]))
        }
        return previous.contains { old in
            shownKeys.contains { $0.type == old.type && $0.key != old.key }
        }
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

    /// The key lines of a scan, without empty lines and comments, in a fixed order, for comparing two scans.
    static func keyLines(_ scan: String) -> [String] {
        scan.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .sorted()
    }

    /// The scan's key lines with the first field replaced by `field`: the name the ssh client looks up.
    static func knownHostsLines(from scan: String, field: String) -> [String] {
        keyLines(scan).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return "\(field) \(parts[1])"
        }
    }

    /// Resolves the endpoint of `target` with `ssh -G`. Nothing connects.
    func endpoint(for target: SSHTarget) async throws -> Endpoint {
        let config = try await runner.run(SSHInstaller.sshExecutable, Self.configArguments(for: target), stdin: nil)
        return Self.endpoint(fromConfig: config.stdout, target: target)
    }

    /// The file trust writes to: the one `ssh -G` names, else the one given to the initializer.
    private func knownHostsFile(for endpoint: Endpoint) -> URL {
        endpoint.knownHostsPath.map { URL(fileURLWithPath: $0) } ?? knownHosts
    }

    /// Whether the file already has this host with a different key of a type shown now.
    private func hasConflict(_ lines: [String], field: String, file: URL) async throws -> Bool {
        let lookup = try await runner.run(
            Self.keygenPath, Self.lookupArguments(host: field, file: file.path), stdin: nil)
        // ssh-keygen answers 1 when there is no such host, or no such file: nothing to conflict with.
        guard lookup.status == 0 else { return false }
        return Self.conflicts(previous: Self.previousKeys(fromLookup: lookup.stdout), shown: lines)
    }

    /// Scans the key types in order and returns the first one the server presents, with its fingerprint.
    public func preview(_ target: SSHTarget) async throws -> HostKeyPreview {
        let endpoint = try await endpoint(for: target)
        if endpoint.viaProxy { throw SSHHostKeyError.viaProxy }
        for keyType in Self.keyTypes {
            let scan = try await runner.run(
                Self.keyscanPath,
                Self.keyscanArguments(host: endpoint.host, port: endpoint.port, keyType: keyType), stdin: nil)
            guard scan.status == 0, !Self.keyLines(scan.stdout).isEmpty else { continue }
            let keygen = try await runner.run(Self.keygenPath, ["-lf", "-"], stdin: Data(scan.stdout.utf8))
            guard let fingerprint = Self.fingerprint(fromKeygen: keygen.stdout) else { throw SSHHostKeyError.noKey }
            let lines = Self.knownHostsLines(from: scan.stdout, field: endpoint.knownHostsField)
            if try await hasConflict(lines, field: endpoint.knownHostsField, file: knownHostsFile(for: endpoint)) {
                throw SSHHostKeyError.keyChangedSincePreviousVisit(host: endpoint.knownHostsField)
            }
            return HostKeyPreview(
                keyType: keyType, fingerprint: fingerprint, scanOutput: scan.stdout, knownHostsLines: lines)
        }
        throw SSHHostKeyError.noKey
    }

    /// Writes the reviewed lines, if a second scan of the same key type gives the same key lines. Anything else
    /// (a different key, a missing key, a jump host) writes nothing.
    public func trust(_ preview: HostKeyPreview, for target: SSHTarget) async throws {
        let endpoint = try await endpoint(for: target)
        if endpoint.viaProxy { throw SSHHostKeyError.viaProxy }
        let scan = try await runner.run(
            Self.keyscanPath,
            Self.keyscanArguments(host: endpoint.host, port: endpoint.port, keyType: preview.keyType), stdin: nil)
        guard scan.status == 0, Self.keyLines(scan.stdout) == Self.keyLines(preview.scanOutput) else {
            throw SSHHostKeyError.changedBetweenChecks
        }
        let file = knownHostsFile(for: endpoint)
        if try await hasConflict(preview.knownHostsLines, field: endpoint.knownHostsField, file: file) {
            throw SSHHostKeyError.keyChangedSincePreviousVisit(host: endpoint.knownHostsField)
        }
        try KnownHostsFile.append(lines: preview.knownHostsLines, to: file)
    }
}
