import Foundation
import Testing
@testable import BanditoKit

@Suite struct PlanDecodingTests {
    private func decode(_ json: String) throws -> Plan {
        try RPCClient.decoder.decode(Plan.self, from: Data(json.utf8))
    }

    @Test func aSizedMaxPlanFromAnOlderDaemonReadsAsMax() throws {
        #expect(try decode(#"{"id": "max_5x", "label": "Max ×5"}"#) == Plan(id: "max", label: "Max"))
        #expect(try decode(#"{"id": "max_20x", "label": "Max ×20"}"#) == Plan(id: "max", label: "Max"))
    }

    @Test func otherPlansKeepTheirNames() throws {
        #expect(try decode(#"{"id": "max", "label": "Max"}"#) == Plan(id: "max", label: "Max"))
        #expect(try decode(#"{"id": "pro", "label": "Pro"}"#) == Plan(id: "pro", label: "Pro"))
        #expect(try decode(#"{"id": "plus", "label": "Plus"}"#) == Plan(id: "plus", label: "Plus"))
    }
}
