import Testing

@testable import BanditoKit

@Suite struct AvatarEmojiTests {
    @Test func gridHasFortyEightDistinctEmoji() {
        #expect(AvatarEmoji.popular.count == 48)
        #expect(Set(AvatarEmoji.popular).count == 48)
        #expect(AvatarEmoji.popular.allSatisfy { $0.count == 1 && AvatarEmoji.isEmoji($0.first!) })
    }

    @Test func lettersAndDigitsAreNotEmoji() {
        for text in ["a", "Z", "1", "9", "#", "*", "©", "я"] {
            #expect(AvatarEmoji.isEmoji(text.first!) == false, "\(text) is not an emoji")
        }
    }

    @Test func emojiPresentationAndVS16AreEmoji() {
        #expect(AvatarEmoji.isEmoji("🦝"))
        #expect(AvatarEmoji.isEmoji("☕"))
        #expect(AvatarEmoji.isEmoji("❤️"))
        #expect(AvatarEmoji.isEmoji("🛠️"))
        #expect(AvatarEmoji.isEmoji("👨‍👩‍👧"))
        #expect(AvatarEmoji.isEmoji("🇩🇪"))
    }

    @Test func textDefaultSymbolWithoutVS16IsNotEmoji() {
        #expect(AvatarEmoji.isEmoji("🛠") == false)
    }

    @Test func lastEmojiIsTheNewestOne() {
        #expect(AvatarEmoji.last(of: "🦝") == "🦝")
        #expect(AvatarEmoji.last(of: "🦝🐱") == "🐱")
        #expect(AvatarEmoji.last(of: "🦝a") == "🦝")
        #expect(AvatarEmoji.last(of: "🦝1") == "🦝")
    }

    @Test func textWithoutEmojiGivesNothing() {
        #expect(AvatarEmoji.last(of: "") == nil)
        #expect(AvatarEmoji.last(of: "a") == nil)
        #expect(AvatarEmoji.last(of: "1") == nil)
        #expect(AvatarEmoji.last(of: "abc 123") == nil)
    }

    @Test func hexFromColorPickerComponents() {
        #expect(AvatarHex.hex(red: 1, green: 0.5, blue: 0) == "#FF8000")
        #expect(AvatarHex.hex(red: 0, green: 0, blue: 0) == "#000000")
        #expect(AvatarHex.hex(red: 2, green: -1, blue: 0.5) == "#FF0080")
    }

    @Test func pastedTextGivesItsNewestEmoji() {
        #expect(AvatarEmoji.last(of: "🦝") == "🦝")
        #expect(AvatarEmoji.last(of: "hello 🦊 world") == "🦊")
        #expect(AvatarEmoji.last(of: "🦝🦊") == "🦊")
        #expect(AvatarEmoji.last(of: "🦝x") == "🦝")
        #expect(AvatarEmoji.last(of: "raccoon") == nil)
        #expect(AvatarEmoji.last(of: "") == nil)
        #expect(AvatarEmoji.last(of: "  ") == nil)
    }

    @Test func searchFindsEmojiByUnicodeName() {
        #expect(AvatarEmoji.search("raccoon", in: AvatarEmoji.popular) == ["🦝"])
        #expect(AvatarEmoji.search("  ROCKET ", in: AvatarEmoji.popular) == ["🚀"])
        #expect(AvatarEmoji.search("heart", in: AvatarEmoji.popular).contains("❤️"))
    }

    @Test func blankSearchKeepsEverythingAndNoMatchKeepsNothing() {
        #expect(AvatarEmoji.search("", in: AvatarEmoji.popular) == AvatarEmoji.popular)
        #expect(AvatarEmoji.search("   ", in: AvatarEmoji.popular) == AvatarEmoji.popular)
        #expect(AvatarEmoji.search("zzzzqq", in: AvatarEmoji.popular).isEmpty)
    }

    @Test func searchNeedsEveryWord() {
        #expect(AvatarEmoji.search("raccoon rocket", in: AvatarEmoji.popular).isEmpty)
        #expect(AvatarEmoji.searchName(of: "❤️") == "heavy black heart")
    }
}
