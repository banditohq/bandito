import Foundation
import Testing

@testable import BanditoL10n

/// `.language("en")` on a suite or a test: every test in it reads the strings of that language, whatever the system
/// language is and whatever other suites switch to while they run in parallel. It sets the task-local
/// `L10n.testingLanguage`, so only the tasks of these tests see it.
///
/// Tests that compare a formatted text with an `L10n` string use it: before `testingLanguage` was task-local, a
/// suite switching to German for a moment made such comparisons fail at random (`statusWord(.idle) == asleep`).
struct PinnedLanguage: SuiteTrait, TestTrait, TestScoping {
    let code: String

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let path = L10n.bundle.path(forResource: code, ofType: "lproj")
        let bundle = try #require(path.flatMap { Bundle(path: $0) }, "no \(code).lproj")
        try await L10n.$testingLanguage.withValue((code: code, bundle: bundle), operation: function)
    }
}

extension Trait where Self == PinnedLanguage {
    /// Every string of the test in `code` (for example `"en"`).
    static func language(_ code: String) -> Self { PinnedLanguage(code: code) }
}
