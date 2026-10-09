import Testing

@testable import BanditoKit

@Suite struct PairLinkTests {
    @Test func buildsTheDeepLinkTheQRCodeCarries() {
        #expect(PairLink.url(code: "amber-otter-maple", host: "vps.example.com")
            == "bandito://pair?code=amber-otter-maple&host=vps.example.com")
    }

    @Test func hostWithPortKeepsTheColon() {
        #expect(PairLink.url(code: "a-b", host: "10.0.0.5:7879") == "bandito://pair?code=a-b&host=10.0.0.5:7879")
    }

    @Test func ampersandAndSpacesAreEscapedSoTheyCannotAddParameters() {
        let link = PairLink.url(code: "x", host: "evil&code=y z")
        #expect(link == "bandito://pair?code=x&host=evil%26code%3Dy%20z")
    }
}
