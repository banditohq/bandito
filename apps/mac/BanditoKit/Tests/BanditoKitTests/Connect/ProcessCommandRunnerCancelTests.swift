import Foundation
import Testing

@testable import BanditoKit

@Suite struct ProcessCommandRunnerCancelTests {
    @Test func aCancelledRunEndsItsChildProcess() async throws {
        let task = Task { try await ProcessCommandRunner().run("/bin/sleep", ["30"], stdin: nil) }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        let result = try await task.value
        #expect(result.status != 0)
        #expect(start.duration(to: .now) < .seconds(5))
    }
}
