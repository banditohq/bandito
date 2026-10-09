import Testing
@testable import BanditoKit

@Suite struct QABuildTests {
    @Test func aQABundleIdGivesItsNumber() {
        for n in 1...5 {
            #expect(QABuild.index(bundleID: "dev.bandito.mac.debug.qa\(n)") == n)
        }
    }

    @Test func onlyOneDigitFrom1To5IsAQACopy() {
        // Leading zeros, 0, 6 and two digits are not QA numbers (the tooling accepts 1..5 only).
        for suffix in ["qa0", "qa01", "qa007", "qa6", "qa9", "qa12", "qa", "qa1x", "qa1.debug", "qa-1", "qa+1", "qa ", "qa١"] {
            #expect(QABuild.index(bundleID: "dev.bandito.mac.debug.\(suffix)") == nil, "\(suffix)")
        }
    }

    @Test func otherBundleIdsAreNotQA() {
        #expect(QABuild.index(bundleID: "dev.bandito.mac") == nil)
        #expect(QABuild.index(bundleID: "dev.bandito.mac.debug") == nil)
        #expect(QABuild.index(bundleID: "dev.bandito.mac.qa1") == nil)
        #expect(QABuild.index(bundleID: "com.example.dev.bandito.mac.debug.qa1") == nil)
        #expect(QABuild.index(bundleID: nil) == nil)
        #expect(!QABuild.isQA(bundleID: "dev.bandito.mac"))
        #expect(QABuild.isQA(bundleID: "dev.bandito.mac.debug.qa2"))
    }
}
