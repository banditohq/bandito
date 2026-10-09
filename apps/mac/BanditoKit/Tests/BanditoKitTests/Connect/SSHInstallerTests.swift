import Foundation
import Testing

@testable import BanditoKit

/// Records what the redeem step was asked to do.
final class RedeemLog: @unchecked Sendable {
    // @unchecked: `calls` is guarded by `lock`.
    struct Call: Equatable {
        var target: String
        var remotePort: Int
        var code: String
        var deviceName: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []

    func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }
}

/// Shared answers of a daemon that behaves like `bandito` does.
enum DaemonAnswers {
    static let probeNew = CommandResult(
        status: 0, stdout: "Linux x86_64\n\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\nNAME=\"Ubuntu\"\n", stderr: "")
    static let probeInstalled = CommandResult(
        status: 0,
        stdout: "Linux x86_64\n/home/deploy/.local/bin/bandito\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\n",
        stderr: "")
    static let installOK = CommandResult(status: 0, stdout: "installed bandito 0.1.0\n", stderr: "")
    static let serviceOK = CommandResult(
        status: 0,
        stdout: #"{"ok":true,"mode":"systemd","listen":"127.0.0.1:7878","socket":"/h/bandito.sock","warnings":[]}"#,
        stderr: "")
    static let infoOK = CommandResult(
        status: 0,
        stdout: #"{"version":"0.1.0","home":"/h","socket":"/h/bandito.sock","listen":"127.0.0.1:7878","running":true,"features":["terminals"]}"#,
        stderr: "")
    static let pairOK = CommandResult(
        status: 0, stdout: #"{"code":"alpha-bravo-charlie-delta-echo-foxtrot","expires_in_ms":600000}"#, stderr: "")

    static let probeCommand =
        "uname -sm; command -v bandito || ls ~/.local/bin/bandito 2>/dev/null; cat /etc/os-release 2>/dev/null | head -3"

    /// Answers by remote command (the last ssh argument). `probe` is the answer to the first step.
    static func answer(probe: CommandResult, service: CommandResult = serviceOK) -> @Sendable (String, [String]) -> CommandResult {
        { executable, arguments in
            if executable == "/usr/bin/scp" { return CommandResult(status: 0, stdout: "", stderr: "") }
            let command = arguments.last ?? ""
            switch command {
            case probeCommand: return probe
            case "sh -s -- --no-service": return installOK
            case _ where command.hasPrefix("mkdir -p") || command.hasPrefix("chmod"):
                return CommandResult(status: 0, stdout: "", stderr: "")
            case _ where command.hasSuffix("service install --json"): return service
            case _ where command.hasSuffix("info --json"): return infoOK
            case _ where command.hasSuffix("pair --json"): return pairOK
            default: return CommandResult(status: 1, stdout: "", stderr: "unexpected command: \(command)")
            }
        }
    }
}

private func failure(_ events: [InstallEvent]) -> InstallError? {
    for event in events {
        if case .failed(let error) = event { return error }
    }
    return nil
}

private func done(_ events: [InstallEvent]) -> PairInfo? {
    for event in events {
        if case .done(let info) = event { return info }
    }
    return nil
}

@Suite struct SSHInstallerTests {
    private let script = Data("#!/bin/sh\necho installing\n".utf8)
    private let target = "deploy@example.com:2222"

    private func makeInstaller(
        runner: ScriptedRunner,
        redeem: RedeemLog,
        script: @escaping SSHInstaller.ScriptSource = { Data() },
        localBinary: URL? = nil
    ) -> SSHInstaller {
        SSHInstaller(
            runner: runner,
            installScript: script,
            localBinary: localBinary,
            redeem: { target, remotePort, code, deviceName in
                redeem.record(
                    RedeemLog.Call(target: target, remotePort: remotePort, code: code, deviceName: deviceName))
                return PairResult(token: "tok-remote", device: Device(id: "dev-1", name: deviceName, createdAt: 1))
            })
    }

    @Test func freshServerIsInstalledStartedPairedAndRedeemed() async throws {
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let redeem = RedeemLog()
        let installer = makeInstaller(runner: runner, redeem: redeem, script: { self.script })

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == nil)
        let info = try #require(done(events))
        #expect(info.server.endpoint == .ssh(target: "deploy@example.com:2222", remotePort: 7878))
        #expect(info.server.token == "tok-remote")
        #expect(info.alreadyInstalled == false)
        #expect(info.warnings.isEmpty)
        #expect(
            redeem.calls
                == [
                    RedeemLog.Call(
                        target: "deploy@example.com:2222", remotePort: 7878,
                        code: "alpha-bravo-charlie-delta-echo-foxtrot", deviceName: "Test Mac")
                ])

        let remote = runner.calls.compactMap(ScriptedRunner.remoteCommand)
        #expect(
            remote
                == [
                    DaemonAnswers.probeCommand,
                    "sh -s -- --no-service",
                    "~/.local/bin/bandito service install --json",
                    "~/.local/bin/bandito info --json",
                    "~/.local/bin/bandito pair --json",
                ])
    }

    @Test func sshAlwaysUsesBatchModeAndThePortOption() async throws {
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let installer = makeInstaller(runner: runner, redeem: RedeemLog(), script: { self.script })

        _ = await collect(installer.install(target: target, deviceName: "Test Mac"))

        let probe = try #require(runner.calls.first)
        #expect(probe.executable == "/usr/bin/ssh")
        #expect(
            probe.arguments
                == [
                    "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                    "-p", "2222", "deploy@example.com", DaemonAnswers.probeCommand,
                ])
        let install = try #require(runner.calls.first { $0.arguments.last == "sh -s -- --no-service" })
        #expect(install.stdin == script)
    }

    @Test func aServerWithTheDaemonAlreadyInstalledSkipsTheInstallScript() async throws {
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeInstalled))
        let redeem = RedeemLog()
        let scriptCalls = ScriptCounter()
        let installer = makeInstaller(runner: runner, redeem: redeem) {
            scriptCalls.bump()
            return self.script
        }

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(scriptCalls.count == 0)
        #expect(runner.calls.compactMap(ScriptedRunner.remoteCommand).contains("sh -s -- --no-service") == false)
        let info = try #require(done(events))
        #expect(info.alreadyInstalled == true)
        #expect(
            runner.calls.compactMap(ScriptedRunner.remoteCommand).contains(
                "'/home/deploy/.local/bin/bandito' service install --json"))
        #expect(redeem.calls.count == 1)
    }

    @Test func authenticationFailureStopsBeforeAnythingChangesOnTheServer() async throws {
        let denied = CommandResult(
            status: 255, stdout: "", stderr: "deploy@example.com: Permission denied (publickey).\n")
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: denied))
        let redeem = RedeemLog()
        let installer = makeInstaller(runner: runner, redeem: redeem, script: { self.script })

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .ssh(.authFailed))
        #expect(runner.calls.count == 1)
        #expect(redeem.calls.isEmpty)
    }

    @Test func unsupportedPlatformStopsAtTheProbe() async throws {
        let freeBSD = CommandResult(status: 0, stdout: "FreeBSD amd64\n\n", stderr: "")
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: freeBSD))
        let installer = makeInstaller(runner: runner, redeem: RedeemLog(), script: { self.script })

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .unsupportedPlatform("FreeBSD amd64"))
        #expect(runner.calls.count == 1)
    }

    @Test func serviceFailureCarriesTheWarnings() async throws {
        let refused = CommandResult(
            status: 1,
            stdout: #"{"ok":false,"mode":"systemd","listen":"127.0.0.1:7878","socket":"/s","warnings":["lingering refused: run sudo loginctl enable-linger deploy"]}"#,
            stderr: "")
        let runner = ScriptedRunner(
            respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew, service: refused))
        let redeem = RedeemLog()
        let installer = makeInstaller(runner: runner, redeem: redeem, script: { self.script })

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(
            failure(events)
                == .serviceFailed("lingering refused: run sudo loginctl enable-linger deploy"))
        #expect(redeem.calls.isEmpty)
    }

    @Test func infoWithoutAListenPortIsABadResponse() async throws {
        let runner = ScriptedRunner { executable, arguments in
            if arguments.last == "~/.local/bin/bandito info --json" {
                return CommandResult(status: 0, stdout: #"{"listen":"tailscale"}"#, stderr: "")
            }
            return DaemonAnswers.answer(probe: DaemonAnswers.probeNew)(executable, arguments)
        }
        let installer = makeInstaller(runner: runner, redeem: RedeemLog(), script: { self.script })

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .badResponse("info"))
    }

    @Test func localBinaryIsCopiedWithScpInsteadOfTheInstallScript() async throws {
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let scriptCalls = ScriptCounter()
        let installer = makeInstaller(
            runner: runner, redeem: RedeemLog(),
            script: {
                scriptCalls.bump()
                return self.script
            },
            localBinary: URL(fileURLWithPath: "/Users/dev/build/bandito"))

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == nil)
        #expect(scriptCalls.count == 0)
        let remote = runner.calls.compactMap(ScriptedRunner.remoteCommand)
        #expect(remote.contains("mkdir -p ~/.local/bin"))
        #expect(remote.contains("chmod 755 ~/.local/bin/bandito"))
        let copy = try #require(runner.calls.first { $0.executable == "/usr/bin/scp" })
        #expect(
            copy.arguments.suffix(4)
                == ["-P", "2222", "/Users/dev/build/bandito", "deploy@example.com:.local/bin/bandito"])
    }

    @Test func withoutAnInstallScriptOrABundledCopyNothingIsRunOnTheServer() async throws {
        // The test bundle has no install.sh, and nothing is downloaded in its place.
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let redeem = RedeemLog()
        let installer = makeInstaller(runner: runner, redeem: redeem, script: SSHInstaller.bundledScript)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .missingInstallScript)
        let remote = runner.calls.compactMap(ScriptedRunner.remoteCommand)
        #expect(remote == [DaemonAnswers.probeCommand])
        #expect(redeem.calls.isEmpty)
    }

    @Test func invalidTargetFailsWithoutRunningAnything() async throws {
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let installer = makeInstaller(runner: runner, redeem: RedeemLog(), script: { self.script })

        let events = await collect(installer.install(target: "-oProxyCommand=evil", deviceName: "Test Mac"))

        #expect(failure(events) == .ssh(.invalidTarget))
        #expect(runner.calls.isEmpty)
    }

    @Test func probeOutputIsParsedIntoPlatformAndInstallState() throws {
        let mac = try RemoteProbe.parse("Darwin arm64\n/Users/u/.local/bin/bandito\n")
        #expect(mac.kernel == "Darwin")
        #expect(mac.arch == "aarch64")
        #expect(mac.installedPath == "/Users/u/.local/bin/bandito")
        #expect(mac.osName == nil)

        let debian = try RemoteProbe.parse("Linux aarch64\n\nPRETTY_NAME=\"Debian GNU/Linux 12\"\n")
        #expect(debian.arch == "aarch64")
        #expect(debian.installedPath == nil)
        #expect(debian.osName == "Debian GNU/Linux 12")

        #expect(throws: InstallError.unsupportedPlatform("Linux riscv64")) {
            try RemoteProbe.parse("Linux riscv64\n\n")
        }
    }
}

/// Counts calls from a `@Sendable` closure.
final class ScriptCounter: @unchecked Sendable {
    // @unchecked: `count` is guarded by `lock`.
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

@Suite struct LocalInstallerTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "local-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeFile(_ url: URL, _ text: String, modified: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Changes when a file is replaced by a rename, and stays when its content is only rewritten in place.
    private func inodeNumber(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? UInt64)
    }

    @Test func copiesTheBundledBinaryAndStartsTheServiceOnThisMac() async throws {
        let home = try makeHome()
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "BIN", modified: Date())
        let runner = ScriptedRunner { _, _ in DaemonAnswers.serviceOK }
        let installer = LocalInstaller(runner: runner, bundledBinary: bundled, home: home)

        let events = await collect(installer.install())

        let installed = home.appending(path: ".local/bin/bandito")
        #expect(try read(installed) == "BIN")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        let call = try #require(runner.calls.first)
        #expect(call.executable == installed.path)
        #expect(call.arguments == ["service", "install", "--json"])
        let info = try #require(done(events))
        #expect(info.server.endpoint == .local(socketPath: home.appending(path: ".bandito/bandito.sock").path))
        #expect(info.server.token == nil)
        #expect(info.alreadyInstalled == false)
    }

    @Test func anInstalledBinaryWithTheSameContentIsKeptAsItIs() async throws {
        let home = try makeHome()
        let bundled = home.appending(path: "bundle/bandito")
        let installed = home.appending(path: ".local/bin/bandito")
        try writeFile(bundled, "SAME", modified: Date())
        try writeFile(installed, "SAME", modified: Date().addingTimeInterval(-3600))
        let inode = try inodeNumber(installed)
        let runner = ScriptedRunner { _, _ in DaemonAnswers.serviceOK }
        let installer = LocalInstaller(runner: runner, bundledBinary: bundled, home: home)

        let events = await collect(installer.install())

        #expect(try inodeNumber(installed) == inode)
        #expect(try read(installed) == "SAME")
        #expect(try #require(done(events)).alreadyInstalled == true)
    }

    @Test func anInstalledBinaryWithDifferentContentIsReplacedEvenWhenItIsNewer() async throws {
        let home = try makeHome()
        let bundled = home.appending(path: "bundle/bandito")
        let installed = home.appending(path: ".local/bin/bandito")
        try writeFile(bundled, "NEW", modified: Date().addingTimeInterval(-3600))
        try writeFile(installed, "NEWER", modified: Date().addingTimeInterval(3600))
        let runner = ScriptedRunner { _, _ in DaemonAnswers.serviceOK }
        let installer = LocalInstaller(runner: runner, bundledBinary: bundled, home: home)

        _ = await collect(installer.install())

        #expect(try read(installed) == "NEW")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
    }

    @Test func aReplacementLeavesNoTemporaryFileBehind() async throws {
        let home = try makeHome()
        let bundled = home.appending(path: "bundle/bandito")
        let installed = home.appending(path: ".local/bin/bandito")
        try writeFile(bundled, "NEW", modified: Date())
        try writeFile(installed, "OLD", modified: Date())
        let runner = ScriptedRunner { _, _ in DaemonAnswers.serviceOK }
        let installer = LocalInstaller(runner: runner, bundledBinary: bundled, home: home)

        _ = await collect(installer.install())

        let names = try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path)
        #expect(names == ["bandito"])
    }

    @Test func withoutABundledBinaryAndNothingInstalledItFails() async throws {
        let home = try makeHome()
        let runner = ScriptedRunner { _, _ in DaemonAnswers.serviceOK }
        let installer = LocalInstaller(runner: runner, bundledBinary: nil, home: home)

        let events = await collect(installer.install())

        #expect(failure(events) == .localBinaryMissing)
        #expect(runner.calls.isEmpty)
    }

    @Test func aFailedServiceInstallIsReported() async throws {
        let home = try makeHome()
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "BIN", modified: Date())
        let refused = CommandResult(
            status: 1,
            stdout: #"{"ok":false,"mode":"launchd","listen":"127.0.0.1:7878","socket":"/s","warnings":["launchctl refused"]}"#,
            stderr: "")
        let runner = ScriptedRunner { _, _ in refused }
        let installer = LocalInstaller(runner: runner, bundledBinary: bundled, home: home)

        let events = await collect(installer.install())

        #expect(failure(events) == .serviceFailed("launchctl refused"))
    }
}
