import Foundation
import Testing

@testable import BanditoUI

/// The main agent of a server is always first in the team list.
@Suite struct LeadAgentTests {
    @Test func mainItemMovesToTheFront() {
        let ids = ["a", "b", "c"]
        #expect(LeadAgent.leadFirst(ids, id: { $0 }, lead: "c") == ["c", "a", "b"])
    }

    @Test func listWithMainFirstOrNoMainIsUnchanged() {
        let ids = ["a", "b", "c"]
        #expect(LeadAgent.leadFirst(ids, id: { $0 }, lead: "a") == ids)
        #expect(LeadAgent.leadFirst(ids, id: { $0 }, lead: nil) == ids)
        #expect(LeadAgent.leadFirst(ids, id: { $0 }, lead: "gone") == ids)
    }
}
