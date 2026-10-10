import Testing

@testable import BanditoKit

@Suite struct AvatarHexTests {
    @Test func acceptsWithOrWithoutHashAndUpperCases() {
        #expect(AvatarHex.normalized("#ff8800") == "#FF8800")
        #expect(AvatarHex.normalized("abc123") == "#ABC123")
        #expect(AvatarHex.normalized("  #0a0B0c ") == "#0A0B0C")
    }

    @Test func rejectsWrongLengthAndNonHexDigits() {
        #expect(AvatarHex.normalized("#ABC") == nil)
        #expect(AvatarHex.normalized("#GGGGGG") == nil)
        #expect(AvatarHex.normalized("#ABCDEF0") == nil)
        #expect(AvatarHex.normalized("") == nil)
        #expect(AvatarHex.normalized("peach") == nil)
    }

    @Test func valueIsTheRGBNumber() {
        #expect(AvatarHex.value("#FF8800") == 0xFF8800)
        #expect(AvatarHex.value("#000000") == 0)
        #expect(AvatarHex.value("peach") == nil)
    }
}
