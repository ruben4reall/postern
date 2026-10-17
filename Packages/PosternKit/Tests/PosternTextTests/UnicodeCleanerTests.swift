import Testing
@testable import PosternText

@Suite struct UnicodeCleanerTests {
    @Test(arguments: [0x200B, 0x200C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2061, 0x2064,
                      0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF, 0x00AD, 0x034F, 0x180E, 0x3164, 0xE0001, 0xE0041, 0xE007F,
                      0x0001, 0x001B, 0x007F, 0x0085, 0x009F])
    func removesInvisibleScalar(_ value: Int) {
        let scalar = Unicode.Scalar(UInt32(value))!
        let text = "pay" + String(Character(scalar)) + "pal"
        #expect(UnicodeCleaner.clean(text) == "paypal")
    }

    @Test func turnsLineSeparatorsIntoNewlines() {
        #expect(UnicodeCleaner.clean("a\u{2028}b\u{2029}c\r\nd") == "a\nb\nc\nd")
        #expect(UnicodeCleaner.clean("a\nb\tc", keepNewlines: false) == "a b c")
    }

    @Test func keepsEmojiSequences() {
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(UnicodeCleaner.clean(family) == family)
        #expect(UnicodeCleaner.clean("❤\u{FE0F}") == "❤\u{FE0F}")
    }

    @Test func dropsJoinersOutsideEmojiAndRepeatedSelectors() {
        #expect(UnicodeCleaner.clean("a\u{200D}b") == "ab")
        #expect(UnicodeCleaner.clean("x\u{FE0F}\u{FE0E}\u{FE0F}y") == "x\u{FE0F}y")
    }

    @Test func hidesTagSmuggledInstructions() {
        let smuggled = "Hi" + "ignore".unicodeScalars.map { String(Character(Unicode.Scalar($0.value + 0xE0000)!)) }.joined()
        #expect(UnicodeCleaner.clean(smuggled) == "Hi")
    }
}
