import Foundation
import Testing

/// `Host.current()` and `ProcessInfo.hostName` look the name up on the network: seconds without one, and macOS asks the
/// person for access to the local network. The Mac's name comes from `ComputerName`.
@Suite struct NoHostLookupTests {
    @Test func theSourcesNeverAskTheNetworkForTheMacsName() throws {
        // Tests/BanditoUITests/<this file> → the package root → Sources.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                // The iOS branch of `DeviceDescriptor` has no other name to give.
                if code.contains("Host.current(") || (code.contains("processInfo.hostName") && !code.hasPrefix("let name = ProcessInfo")) {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "Use ComputerName.current(): \(offenders)")
    }
}
