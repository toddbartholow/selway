import Foundation

/// The invisible scalars that are part of how an emoji is drawn: the
/// zero-width joiner in "👨‍💻" and the variation selector in "❤️". They're
/// Default_Ignorable code points, like the zero-width characters that hide in
/// a name ("nas\u{200D}.local" reads as "nas.local"), so a rule refusing
/// those (ServerAddress's hosts) or replacing them (the sidebar's server
/// names, NetworkServers.displayName) would refuse or mangle a Mac named
/// "Alex’s 👨‍💻 Mac". Where one changes how an emoji is drawn it's allowed;
/// anywhere else, including where it would change nothing visible ("😀"
/// followed by VS16, which is already drawn as an emoji), it's still what it
/// was.
enum EmojiSequence {
    static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"
    /// VS16: the emoji (colour) form of the scalar before it.
    static let emojiSelector: Unicode.Scalar = "\u{FE0F}"
    /// VS15: the text form of the scalar before it.
    static let textSelector: Unicode.Scalar = "\u{FE0E}"
    static let keycap: Unicode.Scalar = "\u{20E3}"

    /// Whether the scalar at `index` is a joiner or a variation selector that
    /// belongs to an emoji sequence:
    /// - VS16 straight after an emoji drawn as text unless asked
    ///   (Emoji but not Emoji_Presentation: "❤️", "©️", "™️"), or in a keycap
    ///   (a digit, "#" or "*", then VS16, then U+20E3: "1️⃣");
    /// - VS15 straight after a Basic Multilingual Plane emoji drawn as an
    ///   emoji unless asked ("⌚︎"). Swift doesn't say which emoji have a text
    ///   form defined; those in that plane do, while most beyond it ("😀")
    ///   have none, so VS15 there would change nothing and is refused;
    /// - a zero-width joiner between two pictographic emoji, each drawn as
    ///   an emoji: an Emoji_Presentation one, or a text-default one with its
    ///   VS16. The one before may carry a skin tone ("👨🏽‍💻", "❤️‍🔥",
    ///   "🧑‍⚕️").
    /// Never after a skin tone, a regional indicator (flag letter) or
    /// another selector; never at the start or end, after a letter, or
    /// before a dot.
    static func isDrawn(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        guard scalars.indices.contains(index), index > 0 else { return false }
        let scalar = scalars[index], before = scalars[index - 1]
        let after: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
        switch scalar {
        case emojiSelector:
            if isTextDefault(before) { return true }
            return isKeycapBase(before) && after == keycap
        case textSelector:
            return isPictographic(before) && before.properties.isEmojiPresentation && before.value <= 0xFFFF
        case zeroWidthJoiner:
            return joinsOnTheLeft(scalars, before: index) && joinsOnTheRight(scalars, after: index)
        default:
            return false
        }
    }

    /// A pictographic emoji: a non-ASCII scalar with Unicode's Emoji property
    /// that isn't a skin tone or a regional indicator. That stands in for
    /// Extended_Pictographic, which Swift doesn't expose (the ASCII ones with
    /// the property are the digits, "#" and "*", emoji only in a keycap).
    static func isPictographic(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.isASCII && scalar.properties.isEmoji && !scalar.properties.isEmojiModifier
            && !isRegionalIndicator(scalar)
    }

    /// An emoji drawn as text unless VS16 follows it (❤, ©, ™).
    private static func isTextDefault(_ scalar: Unicode.Scalar) -> Bool {
        isPictographic(scalar) && !scalar.properties.isEmojiPresentation
    }

    /// What's before the joiner at `index` is an emoji drawn as one: an
    /// Emoji_Presentation emoji, a text-default one with its VS16, or either
    /// of those with a skin tone (on a base that takes one).
    private static func joinsOnTheLeft(_ scalars: [Unicode.Scalar], before index: Int) -> Bool {
        let previous = scalars[index - 1]
        if previous.properties.isEmojiModifier {
            guard index >= 2 else { return false }
            let base = scalars[index - 2]
            return isPictographic(base) && base.properties.isEmojiModifierBase
        }
        if previous == emojiSelector {
            return isDrawn(at: index - 1, in: scalars) && index >= 2 && isPictographic(scalars[index - 2])
        }
        return isPictographic(previous) && previous.properties.isEmojiPresentation
    }

    /// What's after the joiner at `index` is an emoji drawn as one: an
    /// Emoji_Presentation emoji, or a text-default one followed by its VS16.
    private static func joinsOnTheRight(_ scalars: [Unicode.Scalar], after index: Int) -> Bool {
        guard index + 1 < scalars.count else { return false }
        let next = scalars[index + 1]
        guard isPictographic(next) else { return false }
        if next.properties.isEmojiPresentation { return true }
        return index + 2 < scalars.count && scalars[index + 2] == emojiSelector
    }

    private static func isKeycapBase(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || scalar == "#" || scalar == "*"
    }

    private static func isRegionalIndicator(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }
}
