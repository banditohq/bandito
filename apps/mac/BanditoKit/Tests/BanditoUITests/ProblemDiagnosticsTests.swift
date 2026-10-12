import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// What the diagnostics of a report say about the servers and the logs.
@Suite struct ProblemDiagnosticsTests {
    @Test func serversAreNamedByKindNeverByNameOrAddress() {
        let lines = ProblemDiagnostics.serverLines([
            (isThisMac: true, os: "macos", state: .connected, disabled: false),
            (isThisMac: false, os: "linux", state: .reconnecting(attempt: 3), disabled: false),
            (isThisMac: false, os: nil, state: .disconnected, disabled: false),
            (isThisMac: false, os: "linux", state: .connected, disabled: true),
        ])
        #expect(lines.map(\.label) == ["This Mac", "Linux server 1", "Server 2", "Linux server 3"])
        #expect(lines.map(\.state) == ["connected", "reconnecting (attempt 3)", "disconnected", "switched off"])
    }

    @Test func theTextHidesWhatTheLogsLetOut() {
        let diagnostics = ProblemDiagnostics(
            versions: "Bandito for Mac: 0.1.14 (build 1)",
            servers: ProblemDiagnostics.serverLines([(isThisMac: true, os: nil, state: .connected, disabled: false)]),
            appLog: ["10:00:00 [rpc] error: connect to 10.1.2.3 failed for maria@example.com"],
            daemonLog: ["WARN token=" + "ghp_12345678" + "90abcdefghijABCDEFGHIJ123456 at /home/ubuntu/.bandito"],
            daemonLogNote: nil)
        let text = diagnostics.text(redactor: SecretRedactor())
        #expect(!text.contains("10.1.2.3") && !text.contains("maria@") && !text.contains("ghp_") && !text.contains("ubuntu"))
        #expect(text.contains("- This Mac: connected"))
        #expect(text.contains("App log (last 1 lines):") && text.contains("Daemon log (last 1 lines):"))
        #expect(text.contains("Bandito for Mac: 0.1.14 (build 1)"))
    }

    @Test func aLongLineIsCutAndAFenceInsideALogCannotBreakTheBlock() {
        let long = String(repeating: "a b ", count: 200)
        let diagnostics = ProblemDiagnostics(
            versions: "v", servers: [], appLog: ["```" + long], daemonLog: [], daemonLogNote: "(no server)")
        let text = diagnostics.text(redactor: SecretRedactor())
        #expect(text.contains("…"))
        #expect(text.components(separatedBy: "```").count == 5, "two blocks, four fences")
        #expect(text.contains("(no server)"))
        #expect(text.contains("- none"))
    }

    @Test func theAppLogReaderNeverThrowsAndStaysWithinTheLimit() {
        let lines = ProblemDiagnosticsCollector.appLogLines(limit: 5, since: 60)
        #expect(lines.count <= 5)
    }
}
