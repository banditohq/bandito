import Foundation

@testable import BanditoKit

/// A `CommandRunner` that answers from a closure and records every call.
final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    // @unchecked: `calls` is guarded by `lock`.
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var stdin: Data?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (_ executable: String, _ arguments: [String]) -> CommandResult

    init(respond: @escaping @Sendable (_ executable: String, _ arguments: [String]) -> CommandResult) {
        self.respond = respond
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        lock.withLock {
            recorded.append(Call(executable: executable, arguments: arguments, stdin: stdin))
        }
        return respond(executable, arguments)
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    /// The remote command of an ssh call: its last argument.
    static func remoteCommand(_ call: Call) -> String? {
        call.executable.hasSuffix("ssh") ? call.arguments.last : nil
    }
}

/// Writes an executable `ssh` stand-in: a shell script with the given body. Returns its path.
func writeFakeSSH(_ body: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(
        path: "fake-ssh-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "ssh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}
