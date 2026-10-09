import CryptoKit
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

    /// The remote command that runs the install script on a verified archive.
    static let archiveInstallPrefix = "env BANDITO_REQUIRE_SIGNATURE=1 sh -s -- --archive "

    /// Answers by remote command (the last ssh argument). `probe` is the answer to the first step.
    static func answer(probe: CommandResult, service: CommandResult = serviceOK) -> @Sendable (String, [String]) -> CommandResult {
        { executable, arguments in
            if executable == "/usr/bin/scp" { return CommandResult(status: 0, stdout: "", stderr: "") }
            let command = arguments.last ?? ""
            switch command {
            case probeCommand: return probe
            case _ where command.hasPrefix(archiveInstallPrefix): return installOK
            case _ where command.hasPrefix("mkdir -p") || command.hasPrefix("chmod") || command.hasPrefix("rm -f"):
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

private func logs(_ events: [InstallEvent]) -> [String] {
    events.compactMap { event in
        if case .log(let line) = event { return line }
        return nil
    }
}

/// What the runner was asked to do, in order: an ssh call is its remote command, an scp call is `scp <remote path>`
/// (the `<target>:` part of scp's destination is left out).
private func steps(_ runner: ScriptedRunner) -> [String] {
    runner.calls.map { call in
        let last = call.arguments.last ?? ""
        guard call.executable.hasSuffix("scp") else { return last }
        let path = last.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        return "scp \(path)"
    }
}

@Suite struct SSHInstallerTests {
    private let script = Data("#!/bin/sh\necho installing\n".utf8)
    private let target = "deploy@example.com:2222"
    private let asset = TestRelease.asset
    private let remoteArchive = "~/.cache/bandito-install/bandito-x86_64-unknown-linux-gnu.tar.gz"
    private let prepareDirectory = "mkdir -p ~/.cache/bandito-install && chmod 700 ~/.cache/bandito-install"

    /// An installer that runs against `runner`. The release comes from `source` (default: `release`, served as it was
    /// published) and is checked with `releaseKey` (default: the key that signed `release`, since the production key
    /// cannot sign in a test).
    private func makeInstaller(
        runner: ScriptedRunner,
        redeem: RedeemLog,
        script: @escaping SSHInstaller.ScriptSource = { Data() },
        localBinary: URL? = nil,
        devArchive: URL? = nil,
        appVersion: String? = "0.1.0",
        release: TestRelease = TestRelease(),
        source: ReleaseSource? = nil,
        releaseKey: Curve25519.Signing.PublicKey? = nil
    ) -> SSHInstaller {
        SSHInstaller(
            runner: runner,
            installScript: script,
            localBinary: localBinary,
            devArchive: devArchive,
            appVersion: appVersion,
            release: source ?? FakeReleaseSource(release),
            releaseKey: releaseKey ?? release.publicKey,
            redeem: { target, remotePort, code, deviceName in
                redeem.record(
                    RedeemLog.Call(target: target, remotePort: remotePort, code: code, deviceName: deviceName))
                return PairResult(token: "tok-remote", device: Device(id: "dev-1", name: deviceName, createdAt: 1))
            })
    }

    /// A daemon that answers like `bandito` and records what scp copied (the local path, read at copy time).
    private func daemonRunner(
        probe: CommandResult = DaemonAnswers.probeNew, copies: CopyRecorder, service: CommandResult = DaemonAnswers.serviceOK
    ) -> ScriptedRunner {
        let answers = DaemonAnswers.answer(probe: probe, service: service)
        return ScriptedRunner { executable, arguments in
            if executable == "/usr/bin/scp" { copies.record(path: arguments[arguments.count - 2]) }
            return answers(executable, arguments)
        }
    }

    @Test func freshServerIsDownloadedCheckedCopiedInstalledStartedPairedAndRedeemed() async throws {
        let copies = CopyRecorder()
        let runner = daemonRunner(copies: copies)
        let redeem = RedeemLog()
        let release = TestRelease()
        let source = FakeReleaseSource(release)
        let installer = makeInstaller(
            runner: runner, redeem: redeem, script: { self.script }, release: release, source: source)

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

        #expect(source.requests == [FakeReleaseSource.Request(version: "v0.1.0", asset: asset)])
        #expect(
            steps(runner)
                == [
                    DaemonAnswers.probeCommand,
                    prepareDirectory,
                    "scp .cache/bandito-install/\(asset)",
                    "env BANDITO_REQUIRE_SIGNATURE=1 sh -s -- --archive \(remoteArchive) --no-service",
                    "rm -f \(remoteArchive)",
                    "~/.local/bin/bandito service install --json",
                    "~/.local/bin/bandito info --json",
                    "~/.local/bin/bandito pair --json",
                ])
        #expect(copies.all.map(\.data) == [TestRelease.archive])
        // The archive lives in a work directory that the install removes.
        let copied = try #require(copies.all.first)
        #expect(FileManager.default.fileExists(atPath: copied.path) == false)
    }

    @Test func theInstallScriptGoesToStdinOfTheArchiveInstall() async throws {
        let runner = daemonRunner(copies: CopyRecorder())
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
        let install = try #require(runner.calls.first { $0.arguments.last?.hasPrefix("env BANDITO_") == true })
        #expect(install.stdin == script)
        #expect(install.arguments.dropLast() == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-p", "2222", "deploy@example.com"])
    }

    @Test func aServerWithTheDaemonAlreadyInstalledSkipsTheDownloadAndTheInstallScript() async throws {
        let runner = daemonRunner(probe: DaemonAnswers.probeInstalled, copies: CopyRecorder())
        let redeem = RedeemLog()
        let scriptCalls = ScriptCounter()
        let source = FakeReleaseSource(TestRelease())
        let installer = makeInstaller(
            runner: runner, redeem: redeem,
            script: {
                scriptCalls.bump()
                return self.script
            }, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(scriptCalls.count == 0)
        #expect(source.requests.isEmpty)
        #expect(steps(runner).contains { $0.hasPrefix("env BANDITO_") || $0.hasPrefix("scp ") } == false)
        let info = try #require(done(events))
        #expect(info.alreadyInstalled == true)
        #expect(
            steps(runner).contains("'/home/deploy/.local/bin/bandito' service install --json") == true)
        #expect(redeem.calls.count == 1)
    }

    @Test func authenticationFailureStopsBeforeAnythingChangesOnTheServer() async throws {
        let denied = CommandResult(
            status: 255, stdout: "", stderr: "deploy@example.com: Permission denied (publickey).\n")
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: denied))
        let redeem = RedeemLog()
        let source = FakeReleaseSource(TestRelease())
        let installer = makeInstaller(runner: runner, redeem: redeem, script: { self.script }, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .sshFailed(.keyNotAccepted))
        #expect(runner.calls.count == 1)
        #expect(source.requests.isEmpty)
        #expect(redeem.calls.isEmpty)
    }

    @Test func unsupportedPlatformStopsAtTheProbe() async throws {
        let freeBSD = CommandResult(status: 0, stdout: "FreeBSD amd64\n\n", stderr: "")
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: freeBSD))
        let source = FakeReleaseSource(TestRelease())
        let installer = makeInstaller(runner: runner, redeem: RedeemLog(), script: { self.script }, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .unsupportedPlatform("FreeBSD amd64"))
        #expect(runner.calls.count == 1)
        #expect(source.requests.isEmpty)
    }

    @Test func anAmd64ServerGetsTheX86Asset() async throws {
        let amd64 = CommandResult(status: 0, stdout: "Linux amd64\n\n", stderr: "")
        let source = FakeReleaseSource(TestRelease())
        let installer = makeInstaller(
            runner: ScriptedRunner(respond: DaemonAnswers.answer(probe: amd64)), redeem: RedeemLog(),
            script: { self.script }, source: source)

        _ = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(source.requests.first?.asset == asset)
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

    // MARK: release checks

    @Test func aBadSignatureStopsBeforeAnythingIsCopied() async throws {
        let release = TestRelease()
        let impostor = TestRelease()
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let redeem = RedeemLog()
        // The release is signed by another key than the one the installer trusts.
        let installer = makeInstaller(
            runner: runner, redeem: redeem, script: { self.script }, release: release,
            source: FakeReleaseSource(impostor), releaseKey: release.publicKey)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .releaseCheckFailed(.badSignature))
        #expect(steps(runner) == [DaemonAnswers.probeCommand])
        #expect(redeem.calls.isEmpty)
    }

    @Test func aTamperedArchiveStopsBeforeAnythingIsCopied() async throws {
        let release = TestRelease()
        let source = FakeReleaseSource(
            archive: Data("tampered".utf8), sums: release.sums, signatureBase64: try release.signatureFile())
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let installer = makeInstaller(
            runner: runner, redeem: RedeemLog(), script: { self.script }, release: release, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .releaseCheckFailed(.checksumMismatch))
        #expect(steps(runner) == [DaemonAnswers.probeCommand])
    }

    @Test func anArchiveTheSignedListDoesNotNameStopsTheInstall() async throws {
        let release = TestRelease()
        let sums = Data("\(testSHA256Hex(TestRelease.archive))  bandito-aarch64-apple-darwin.tar.gz\n".utf8)
        let source = FakeReleaseSource(
            archive: TestRelease.archive, sums: sums, signatureBase64: try release.signature(of: sums))
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let installer = makeInstaller(
            runner: runner, redeem: RedeemLog(), script: { self.script }, release: release, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .releaseCheckFailed(.notListed))
        #expect(steps(runner) == [DaemonAnswers.probeCommand])
    }

    @Test func aFailedDownloadStopsBeforeAnythingIsCopied() async throws {
        let source = FakeReleaseSource(
            archive: TestRelease.archive, sums: Data(), signatureBase64: "",
            failure: .downloadFailed("HTTP 500 from github.com"))
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let installer = makeInstaller(runner: runner, redeem: RedeemLog(), script: { self.script }, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .downloadFailed("HTTP 500 from github.com"))
        #expect(steps(runner) == [DaemonAnswers.probeCommand])
    }

    @Test func aReleaseWithoutTheAppsVersionFallsBackToLatestWithAWarning() async throws {
        let release = TestRelease()
        let source = FakeReleaseSource(
            archive: TestRelease.archive, sums: release.sums, signatureBase64: try release.signatureFile(),
            fellBackToLatest: true)
        let runner = daemonRunner(copies: CopyRecorder())
        let installer = makeInstaller(
            runner: runner, redeem: RedeemLog(), script: { self.script }, release: release, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == nil)
        #expect(done(events) != nil)
        #expect(logs(events).contains { $0.contains("v0.1.0") && $0.contains("latest") })
    }

    @Test func aBuildWithoutAVersionAsksForLatestWithoutAWarning() async throws {
        let source = FakeReleaseSource(TestRelease())
        let runner = daemonRunner(copies: CopyRecorder())
        let installer = makeInstaller(
            runner: runner, redeem: RedeemLog(), script: { self.script }, appVersion: nil, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(source.requests == [FakeReleaseSource.Request(version: nil, asset: asset)])
        #expect(logs(events).isEmpty)
    }

    @Test func theArchiveIsRemovedFromTheServerEvenWhenTheInstallFails() async throws {
        let answers = DaemonAnswers.answer(probe: DaemonAnswers.probeNew)
        let runner = ScriptedRunner { executable, arguments in
            if arguments.last?.hasPrefix("env BANDITO_") == true {
                return CommandResult(status: 1, stdout: "", stderr: "installer exploded\n")
            }
            return answers(executable, arguments)
        }
        let redeem = RedeemLog()
        let installer = makeInstaller(runner: runner, redeem: redeem, script: { self.script })

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .step("Installing Bandito", detail: "installer exploded"))
        #expect(steps(runner).last == "rm -f \(remoteArchive)")
        #expect(redeem.calls.isEmpty)
    }

    @Test func aFailedCopyDoesNotLeaveTheArchiveBehind() async throws {
        let answers = DaemonAnswers.answer(probe: DaemonAnswers.probeNew)
        let runner = ScriptedRunner { executable, arguments in
            if executable == "/usr/bin/scp" {
                return CommandResult(status: 1, stdout: "", stderr: "scp: disk full\n")
            }
            return answers(executable, arguments)
        }
        let installer = makeInstaller(runner: runner, redeem: RedeemLog(), script: { self.script })

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .step("Copying Bandito", detail: "scp: disk full"))
        #expect(steps(runner).last == "rm -f \(remoteArchive)")
        #expect(steps(runner).contains { $0.hasPrefix("env BANDITO_") } == false)
    }

    @Test func aDevArchiveIsInstalledWithoutDownloadOrSignatureCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "dev-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let devArchive = directory.appending(path: asset)
        let devBytes = Data("a local build, not signed".utf8)
        try devBytes.write(to: devArchive)
        let copies = CopyRecorder()
        let source = FakeReleaseSource(TestRelease())
        let runner = daemonRunner(copies: copies)
        let redeem = RedeemLog()
        let installer = makeInstaller(
            runner: runner, redeem: redeem, script: { self.script }, devArchive: devArchive, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == nil)
        #expect(done(events) != nil)
        #expect(source.requests.isEmpty)
        #expect(copies.all.map(\.data) == [devBytes])
        #expect(
            steps(runner)
                == [
                    DaemonAnswers.probeCommand,
                    prepareDirectory,
                    "scp .cache/bandito-install/\(asset)",
                    "env BANDITO_REQUIRE_SIGNATURE=1 sh -s -- --archive \(remoteArchive) --no-service",
                    "rm -f \(remoteArchive)",
                    "~/.local/bin/bandito service install --json",
                    "~/.local/bin/bandito info --json",
                    "~/.local/bin/bandito pair --json",
                ])
        #expect(redeem.calls.count == 1)
    }

    @Test func localBinaryIsCopiedWithScpInsteadOfTheInstallScript() async throws {
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let scriptCalls = ScriptCounter()
        let source = FakeReleaseSource(TestRelease())
        let installer = makeInstaller(
            runner: runner, redeem: RedeemLog(),
            script: {
                scriptCalls.bump()
                return self.script
            },
            localBinary: URL(fileURLWithPath: "/Users/dev/build/bandito"), source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == nil)
        #expect(scriptCalls.count == 0)
        #expect(source.requests.isEmpty)
        let remote = runner.calls.compactMap(ScriptedRunner.remoteCommand)
        #expect(remote.contains("mkdir -p ~/.local/bin"))
        #expect(remote.contains("chmod 755 ~/.local/bin/bandito"))
        let copy = try #require(runner.calls.first { $0.executable == "/usr/bin/scp" })
        #expect(
            copy.arguments.suffix(4)
                == ["-P", "2222", "/Users/dev/build/bandito", "deploy@example.com:.local/bin/bandito"])
    }

    @Test func withoutAnInstallScriptOrABundledCopyNothingIsDownloadedOrRunOnTheServer() async throws {
        // The test bundle has no install.sh. The script is read before the download, so nothing else happens.
        let runner = ScriptedRunner(respond: DaemonAnswers.answer(probe: DaemonAnswers.probeNew))
        let redeem = RedeemLog()
        let source = FakeReleaseSource(TestRelease())
        let installer = makeInstaller(
            runner: runner, redeem: redeem, script: SSHInstaller.bundledScript, source: source)

        let events = await collect(installer.install(target: target, deviceName: "Test Mac"))

        #expect(failure(events) == .missingInstallScript)
        #expect(steps(runner) == [DaemonAnswers.probeCommand])
        #expect(source.requests.isEmpty)
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

        #expect(try RemoteProbe.parse("Linux amd64\n\n").arch == "x86_64")

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
