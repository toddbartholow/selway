import Foundation
import Testing
@testable import SelwayCore

@Suite struct EmojiSequenceTests {
    private func drawn(_ text: String) -> [Bool] {
        let scalars = Array(text.unicodeScalars)
        return scalars.indices.map { EmojiSequence.isDrawn(at: $0, in: scalars) }
    }

    @Test func joinersAndSelectorsInsideEmojiAreDrawn() {
        #expect(drawn("👨\u{200D}💻") == [false, true, false])
        // VS16 on a text-default emoji: ❤ © ™.
        #expect(drawn("❤\u{FE0F}") == [false, true])
        #expect(drawn("©\u{FE0F}") == [false, true])
        #expect(drawn("™\u{FE0F}") == [false, true])
        // VS15 on an emoji-default one in the Basic Multilingual Plane.
        #expect(drawn("⌚\u{FE0E}") == [false, true])
        #expect(drawn("❤\u{FE0F}\u{200D}🔥") == [false, true, true, false])
        #expect(drawn("👨🏽\u{200D}💻") == [false, false, true, false])
        #expect(drawn("🧑\u{200D}⚕\u{FE0F}") == [false, true, false, true])
        #expect(drawn("1\u{FE0F}\u{20E3}") == [false, true, false])
    }

    @Test func elsewhereTheyAreNot() {
        #expect(drawn("nas\u{200D}.local").contains(true) == false)
        #expect(drawn("a\u{FE0F}") == [false, false])
        #expect(drawn("1\u{FE0F}") == [false, false])
        #expect(drawn("\u{200D}👨") == [false, false])
        #expect(drawn("👨\u{200D}") == [false, false])
        #expect(drawn("👨\u{200D}x") == [false, false, false])
        #expect(drawn("x\u{FE0F}\u{200D}👨") == [false, false, false, false])
        #expect(drawn("👨\u{200B}💻") == [false, false, false])
        #expect(drawn("👨\u{FE00}") == [false, false])
    }

    @Test func selectorsThatWouldChangeNothingAreNotDrawn() {
        // 😀 is drawn as an emoji already, and has no text form.
        #expect(drawn("😀\u{FE0F}") == [false, false])
        #expect(drawn("😀\u{FE0E}") == [false, false])
        // © is drawn as text already.
        #expect(drawn("©\u{FE0E}") == [false, false])
        // Not after a skin tone, a flag letter or another selector.
        #expect(drawn("👨🏽\u{FE0F}") == [false, false, false])
        #expect(drawn("🇺\u{FE0F}") == [false, false])
        #expect(drawn("🇺\u{FE0E}") == [false, false])
        #expect(drawn("❤\u{FE0F}\u{FE0F}") == [false, true, false])
    }

    @Test func joinersOnlyJoinEmojiDrawnAsEmoji() {
        // Text-default emoji without their VS16.
        #expect(drawn("™\u{200D}©") == [false, false, false])
        #expect(drawn("❤\u{200D}🔥") == [false, false, false])
        // Flag letters and bare skin tones.
        #expect(drawn("🇺\u{200D}🇸") == [false, false, false])
        #expect(drawn("🏽\u{200D}🏽") == [false, false, false])
        #expect(drawn("👨\u{200D}🏽") == [false, false, false])
        // A skin tone on something that doesn't take one.
        #expect(drawn("💻🏽\u{200D}👨") == [false, false, false, false])
    }
}
