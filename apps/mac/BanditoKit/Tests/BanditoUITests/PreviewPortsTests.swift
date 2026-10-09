import BanditoKit
import Testing

@testable import BanditoUI

@Suite struct PreviewPortsTests {
    @Test func agentAndTerminalPortsAlwaysShow() {
        #expect(PreviewPorts.isPreviewable(number: 80, process: "node", owner: .agent))
        #expect(PreviewPorts.isPreviewable(number: 5000, process: "python", owner: .terminal))
    }

    @Test func portsInThePreviewRangeShowWhenNoSystemServiceOwnsThem() {
        #expect(PreviewPorts.isPreviewable(number: 3000, process: "t3", owner: nil))
        #expect(PreviewPorts.isPreviewable(number: 9999, process: "adb", owner: nil))
    }

    @Test func portsOutsideTheRangeWithoutAnOwnerAreHidden() {
        #expect(!PreviewPorts.isPreviewable(number: 2999, process: "t3", owner: nil))
        #expect(!PreviewPorts.isPreviewable(number: 10_000, process: "adb", owner: nil))
        #expect(!PreviewPorts.isPreviewable(number: 631, process: "cupsd", owner: nil))
    }

    @Test func macOSServicesAreHiddenEvenInTheRange() {
        #expect(!PreviewPorts.isPreviewable(number: 5000, process: "ControlCe", owner: nil))
        #expect(!PreviewPorts.isPreviewable(number: 7000, process: "ControlCenter", owner: nil))
        #expect(!PreviewPorts.isPreviewable(number: 3689, process: "rapportd", owner: nil))
    }

    @Test func daemonPortShowsWithItsOwner() {
        #expect(PreviewPorts.isPreviewable(number: 3773, process: "bandito", owner: .daemon))
    }
}
