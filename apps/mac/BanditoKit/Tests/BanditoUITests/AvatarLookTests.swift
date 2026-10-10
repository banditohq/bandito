import BanditoKit
import Testing

@testable import BanditoUI

@Suite struct AvatarLookTests {
    @Test func unsavedAvatarTakesTheNameAutomaticLook() {
        let look = AvatarLook(spec: nil, name: "Forge")
        let resolved = AvatarResolver.resolve(name: "Forge", color: nil, face: .auto)
        #expect(look.palette == resolved.color)
        #expect(look.face == resolved.face)
        #expect(look.customHex == nil)
        #expect(look.emoji == nil)
    }

    @Test func savedPaletteLookAndEmojiAreRead() {
        let look = AvatarLook(spec: AvatarSpec(color: "rose", face: "dots", emoji: "🦝"), name: "Forge")
        #expect(look.palette == .rose)
        #expect(look.face == .dots)
        #expect(look.emoji == "🦝")
        #expect(look.wireColor == "rose")
    }

    @Test func customHexWinsOnTheWireButKeepsAPalette() {
        let look = AvatarLook(spec: AvatarSpec(color: "#ff8800", face: "carets"), name: "Forge")
        #expect(look.customHex == "#FF8800")
        #expect(look.wireColor == "#FF8800")
        #expect(look.palette == AvatarResolver.resolve(name: "Forge", color: nil, face: .auto).color)
    }

    @Test func invalidColorFallsBackToThePalette() {
        let look = AvatarLook(spec: AvatarSpec(color: "#zzzzzz", face: "dots"), name: "Forge")
        #expect(look.customHex == nil)
        #expect(look.wireColor == look.palette.rawValue)
    }

    @Test func autoFaceNeverGoesOnTheWire() {
        let look = AvatarLook(spec: AvatarSpec(color: "sky", face: "auto"), name: "Forge")
        #expect(look.spec.face != "auto")
        #expect(AvatarFace(rawValue: look.spec.face) != nil)
    }

    @Test func specCarriesEmojiAndOmitsItWhenNone() {
        var look = AvatarLook(palette: .sky, customHex: nil, face: .wink, emoji: "🦝")
        #expect(look.spec == AvatarSpec(color: "sky", face: "wink", emoji: "🦝"))
        look.emoji = nil
        #expect(look.spec == AvatarSpec(color: "sky", face: "wink"))
    }
}
